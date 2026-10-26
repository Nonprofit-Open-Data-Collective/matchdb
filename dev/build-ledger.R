# Phase 5 step 6: build the observation ledger on a built database, rebuild
# name and address from it, and compare them with what today's ingests wrote.
#
#   Rscript dev/build-matchdb.R             # first: today's build
#   Rscript dev/build-ledger.R              # ledger, rollups, comparison report
#   Rscript dev/build-ledger.R --install    # ...then swap the rollups in and
#                                           #    rebuild everything downstream
#
# Without --install nothing compile reads is changed: the rollups sit beside the
# live tables as rollup_name and rollup_address. With it, the live tables are
# kept as name_legacy and address_legacy, so the swap can be undone by renaming.
#
# The step 6 checks then run on the installed database, unchanged:
#   Rscript dev/verify/run-gate.R           # Phase 1 gate: still three zeros?
#   Rscript dev/verify/phase2-measure.R     # Phase 2: still +146 YES?
#   Rscript dev/check-build.R               # still 36 of 36?

suppressMessages(pkgload::load_all(".", quiet = TRUE))
options(width = 200, warn = 1)
source("dev/build-versions.R")
install <- "--install" %in% commandArgs(trailingOnly = TRUE)

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
cat("npmatch signature", npmatch::np_normalize_signature(), "\n")
con <- md_db()
on.exit(md_db_close(con), add = TRUE)
if (!DBI::dbExistsTable(con, "entity")) stop("no entity table: run dev/build-matchdb.R first")

step("ledger", md_build_ledger(con, V))
step("text-keyed derived columns", md_build_text_derived(con))
step("rollups", md_build_rollups(con))

cat("\n==== rollups against today's tables\n")
cmp <- md_compare_rollups(con)
print(cmp, row.names = FALSE)
cat("\n==== step 3 measurement: rows against distinct strings\n")
print(md_text_stats(con))

if (install) {
  step("install rollups", md_install_rollups(con))
  # everything after the ingests in dev/build-matchdb.R that reads name or address
  step("guards", md_guard_observed(con))
  step("census geography", md_ingest_geocode(con = con, version = V$address_geocoded))
  step("websites", md_ingest_websites(con = con, efile_version = V$efile,
                                      f1023ez_version = V$f1023ez,
                                      e_postcard_version = V$e_postcard))
  step("compact tables", md_build_compact(con = con))
  step("groups", md_build_groups(con = con))
  step("identifier keys", md_build_ein_key(con = con))
  step("clusters", md_build_clusters(con = con))
  step("statistics cells", md_build_stats(con = con))
  DBI::dbExecute(con, "CHECKPOINT")
  cat("\ninstalled. Now run the Phase 1 gate, the Phase 2 measurement and check-build.\n")
} else {
  cat("\nnot installed. Review the comparison, then rerun with --install.\n")
}
cat(sprintf("\n%.1f min\n", as.numeric(difftime(Sys.time(), t0, units = "mins"))))
