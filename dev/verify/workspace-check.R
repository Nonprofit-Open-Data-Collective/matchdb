#!/usr/bin/env Rscript
# The workspace on real data (dev/TRANCHES.md, "The workspace and its log"):
#  1. two tranche publishes of the same database give the same build id, so an
#     unchanged file keeps its md5 and an update reuses it;
#  2. a fresh workspace against the live remote: list, fetch, compile, then
#     read the log and the state back.
#
#   MATCHDB_DATA=<root holding db/> Rscript dev/verify/workspace-check.R <scratch dir>
suppressMessages(devtools::load_all(".", quiet = TRUE))
scratch <- commandArgs(TRUE)[1]; stopifnot(!is.na(scratch))
unlink(scratch, recursive = TRUE); dir.create(scratch, recursive = TRUE)
mins <- function(t0) as.numeric(difftime(Sys.time(), t0, units = "mins"))
ok <- TRUE

cat("== 1. the same database twice\n")
con <- md_db(read_only = TRUE)
ids <- character()
for (k in c("a", "b")) {
  t0 <- Sys.time()
  d <- withr::with_options(list(matchdb.log = FALSE),
                           suppressMessages(md_publish_tranches(con, file.path(scratch, k))))
  ids[k] <- basename(d)
  cat(sprintf("  publish %s: %s, %.1f min\n", k, ids[k], mins(t0)))
}
md_db_close(con)
dd <- withr::with_options(list(matchdb.log = FALSE),
                          md_tranche_diff(md_tranche_manifest(ids[["a"]], root = file.path(scratch, "a"), local = TRUE),
                                          md_tranche_manifest(ids[["b"]], root = file.path(scratch, "b"), local = TRUE)))
cat(sprintf("  same build id %s; files same %d of %d\n", identical(ids[["a"]], ids[["b"]]),
            sum(dd$status == "same"), nrow(dd)))
ok <- ok && identical(ids[["a"]], ids[["b"]])
unlink(file.path(scratch, c("a", "b")), recursive = TRUE)

cat("\n== 2. a fresh workspace against", md_remote(), "\n")
Sys.setenv(MATCHDB_DATA = file.path(scratch, "workspace"))
sp <- md_spec(layers = "bmf_active", names = c("legal", "dba"), addresses = "mailing", label = "active-legal")
print(md_tranches(sp))
t0 <- Sys.time(); suppressMessages(md_fetch_tranches(sp))
con <- md_tranche_db(); r <- suppressMessages(md_compile(sp, con)); md_db_close(con)
cat(sprintf("\nfetched and compiled %s rows in %.1f min\n\n", format(nrow(r$reference), big.mark = ","), mins(t0)))
print(md_status())
cat("\nmd_log():\n")
print(md_log()[, c("run_id", "kind", "build", "spec_hash", "files", "downloaded", "bytes",
                   "elapsed_seconds", "normalize_signature", "note")], row.names = FALSE)
f <- md_log_run(md_log("fetch_tranches")$run_id)
cat("\nthe fetch's detail file, first rows:\n")
print(utils::head(f[, c("path", "status", "rows", "bytes", "md5")], 4), row.names = FALSE)
cat("\nlogs/:", paste(list.files(file.path(md_data_root(), "logs")), collapse = "  "), "\n")
ok <- ok && nrow(md_log()) == 2 && identical(md_status()$last_compile$rows, nrow(r$reference))
cat(sprintf("\n%s\n", if (ok) "WORKSPACE OK" else "WORKSPACE PROBLEM"))
quit(status = if (ok) 0 else 1)
