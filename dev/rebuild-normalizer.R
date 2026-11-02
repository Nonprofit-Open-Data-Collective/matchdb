# Adopt a new normalizer signature on a built database (matchdb#29).
#
# Derived columns are stored per string and per signature, so the new
# signature's rows go in beside the old ones and the two can be compared before
# anything compile reads is changed.
#
#   Rscript dev/rebuild-normalizer.R <old-sig>                    # derive + diff
#   Rscript dev/rebuild-normalizer.R <old-sig> --install          # ...then adopt
#   Rscript dev/rebuild-normalizer.R <old-sig> --install --prune  # ...and tidy
#   Rscript dev/rebuild-normalizer.R <old-sig> --drop-old         # once no
#                                                 # published tier names it
#
# Without --install the new rows sit in name_text_derived and
# address_text_derived and nothing else moves. --install relinks name_derived
# and address_derived to the installed signature and rebuilds every table
# dev/build-matchdb.R builds after the derived columns. It then reports the
# stored signatures nothing needs any more -- neither the installed one, nor
# <old-sig>, nor one a published tier names -- and --prune deletes them, which
# is the retention rule the staging tables otherwise rely on a maintainer to
# remember. Then rerun the gates:
#   Rscript dev/verify/run-gate.R; Rscript dev/verify/phase2-measure.R
#   Rscript dev/check-build.R
# and republish the tiers (dev/verify/release/publish-tiers.R).

suppressMessages(pkgload::load_all(".", quiet = TRUE))
options(width = 200, warn = 1)
a <- commandArgs(trailingOnly = TRUE)
old <- a[!startsWith(a, "--")][1]
install <- "--install" %in% a
drop_old <- "--drop-old" %in% a
prune <- "--prune" %in% a
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
  sigs <- md_published_signatures()
  if (old %in% sigs) stop("published tier(s) still name ", old, ": ",
                          paste(names(sigs)[sigs == old], collapse = ", "))
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

  # Nothing prunes the staging tables on its own: md_build_text_derived() only
  # adds rows for the installed signature, so every signature move leaves
  # another ~20.8M rows behind (0.75 GB) until someone remembers them. Three
  # sets had accumulated by 2026-11-02. Report them here, where the move
  # happens, rather than leaving it to be noticed later -- but delete only on
  # --prune, because the keys a stale set holds are the only way to diff back
  # to it without re-deriving every string.
  cat("\n==== stored signatures nothing needs any more\n")
  cat("keeping", new, "(installed),", old, "(the diff's baseline)")
  pub <- unique(unname(md_published_signatures()))
  if (length(pub)) cat(", and published:", paste(setdiff(pub, c(new, old)), collapse = " "))
  cat("\n")
  gone <- md_droppable_signatures(con, keep = c(new, old))
  if (!is.null(gone) && nrow(gone)) {
    print(gone, row.names = FALSE)
    if (prune) {
      for (s in unique(gone$normalize_signature)) {
        for (t in c("name_text_derived", "address_text_derived")) {
          n <- DBI::dbExecute(con, sprintf("DELETE FROM %s WHERE normalize_signature = %s",
                                           t, DBI::dbQuoteString(con, s)))
          cat(sprintf("%s: %s rows under %s dropped\n", t, format(n, big.mark = ","), s))
        }
      }
      DBI::dbExecute(con, "CHECKPOINT")
      print(md_text_stats(con)$signatures, row.names = FALSE)
    } else {
      cat(sprintf("%s row(s) droppable. Rerun with --prune, or drop one with --drop-old.\n",
                  format(sum(gone$n), big.mark = ",")))
    }
  } else {
    cat("none\n")
  }
} else {
  cat("\nnot installed. Review the diff, then rerun with --install.\n")
}
cat(sprintf("\n%.1f min\n", as.numeric(difftime(Sys.time(), t0, units = "mins"))))
