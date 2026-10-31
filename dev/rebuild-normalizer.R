# Adopt a new normalizer signature on a built database (matchdb#29).
#
# Derived columns are stored per string and per signature, so the new
# signature's rows go in beside the old ones and the two can be compared before
# anything compile reads is changed.
#
#   Rscript dev/rebuild-normalizer.R <old-sig>              # derive + diff only
#   Rscript dev/rebuild-normalizer.R <old-sig> --install    # ...then adopt it
#   Rscript dev/rebuild-normalizer.R <old-sig> --drop-old   # once no published
#                                                           # tier names <old-sig>
#
# Without --install the new rows sit in name_text_derived and
# address_text_derived and nothing else moves. --install relinks name_derived
# and address_derived to the installed signature and rebuilds every table
# dev/build-matchdb.R builds after the derived columns. Then rerun the gates:
#   Rscript dev/verify/run-gate.R; Rscript dev/verify/phase2-measure.R
#   Rscript dev/check-build.R
# and republish the tiers (dev/verify/release/publish-tiers.R).

suppressMessages(pkgload::load_all(".", quiet = TRUE))
options(width = 200, warn = 1)
a <- commandArgs(trailingOnly = TRUE)
old <- a[!startsWith(a, "--")][1]
install <- "--install" %in% a
drop_old <- "--drop-old" %in% a
if (is.na(old)) stop("usage: Rscript dev/rebuild-normalizer.R <old-signature> [--install | --drop-old]")
new <- npnormalize::np_normalize_signature()
if (identical(old, new)) stop("the installed normalizer is already ", new)

t0 <- Sys.time()
step <- function(label, expr) {
  t1 <- Sys.time()
  cat(sprintf("\n==== %s  [%s]\n", label, format(t1, "%H:%M:%S")))
  force(expr)
  cat(sprintf("==== %s done in %.1f min (%.1f min total)\n", label,
              as.numeric(difftime(Sys.time(), t1, units = "mins")),
              as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  invisible(NULL)
}

cat("data root:", md_data_root(), "\n")
cat(sprintf("npnormalize %s | old %s -> new %s\n",
            as.character(utils::packageVersion("npnormalize")), old, new))
con <- md_db()
on.exit(md_db_close(con), add = TRUE)

if (drop_old) {
  pub <- md_path("publish", "latest.json")
  if (file.exists(pub)) {
    l <- jsonlite::read_json(pub)
    sigs <- vapply(names(l), function(lab) jsonlite::read_json(md_path(
      "publish", lab, l[[lab]]$spec_hash, "stamp.json"))$normalize_signature, "")
    if (old %in% sigs) stop("published tier(s) still name ", old, ": ",
                            paste(names(sigs)[sigs == old], collapse = ", "))
  }
  for (t in c("name_text_derived", "address_text_derived")) {
    n <- DBI::dbExecute(con, sprintf("DELETE FROM %s WHERE normalize_signature = %s",
                                     t, DBI::dbQuoteString(con, old)))
    cat(sprintf("%s: %s rows under %s dropped\n", t, format(n, big.mark = ","), old))
  }
  DBI::dbExecute(con, "CHECKPOINT")
  print(md_text_stats(con)$signatures, row.names = FALSE)
  quit(save = "no")
}

step("text-keyed derived columns", md_build_text_derived(con))
print(md_check_text_derived(con), row.names = FALSE)

cat("\n==== what the new normalizer changes\n")
d <- md_normalizer_diff(con, old = old, new = new, examples = 10L)
print(d)
saveRDS(d, md_path("work", sprintf("normalizer-diff-%s-%s.rds", old, new), create = FALSE))

if (install) {
  step("link derived columns", print(md_link_derived(con)))
  # everything after "derived columns" in dev/build-matchdb.R
  step("compact tables", md_build_compact(con = con))
  step("groups", md_build_groups(con = con))
  step("places", md_build_places(con))
  step("identifier keys", md_build_ein_key(con = con))
  step("clusters", md_build_clusters(con = con))
  step("statistics cells", md_build_stats(con = con))
  DBI::dbExecute(con, "CHECKPOINT")
  cat("\ninstalled", new, ". Now run the gates, then republish.\n")
} else {
  cat("\nnot installed. Review the diff, then rerun with --install.\n")
}
cat(sprintf("\n%.1f min\n", as.numeric(difftime(Sys.time(), t0, units = "mins"))))
