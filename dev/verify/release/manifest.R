# MANIFEST.json for the released database, in the format md_fetch_db() reads.
suppressMessages(pkgload::load_all(".", quiet = TRUE))
a <- commandArgs(TRUE); db <- a[1]; key <- a[2]; out <- a[3]; full <- identical(a[4], "full")
con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
tabs <- sort(DBI::dbListTables(con))
tables <- lapply(setNames(tabs, tabs), function(t) as.numeric(.md_n(con, t)))
dv <- DBI::dbGetQuery(con, "SELECT version() v")$v
DBI::dbDisconnect(con, shutdown = TRUE)
pins <- Sys.glob(file.path(md_data_root(), "sources", "*", "*", "PIN.dcf"))
sources <- lapply(sort(pins), function(f) {
  p <- as.list(as.data.frame(read.dcf(f), stringsAsFactors = FALSE))
  p[vapply(p, function(v) !is.na(v) && nzchar(v), logical(1))]
})
git <- function(...) system2("git", c(...), stdout = TRUE)
man <- list(database = key, size_bytes = file.size(db),
            md5 = unname(tools::md5sum(db)), built = format(file.mtime(db), "%Y-%m-%dT%H:%M:%S%z"),
            matchdb_branch = git("rev-parse", "--abbrev-ref", "HEAD"),
            matchdb_commit = git("rev-parse", "HEAD"),
            build_script = "dev/build-matchdb.R; dev/build-ledger.R --install",
            check_script = "dev/check-build.R",
            npmatch_version = as.character(utils::packageVersion("npmatch")),
            npmatch_commit = as.character(utils::packageDescription("npmatch")$RemoteSha %||% NA),
            normalize_signature = npmatch::np_normalize_signature(),
            duckdb_version = sub("^v", "", dv),
            ledger = full,
            contents = if (full) "maintainer copy: every table, including the observation ledger (obs, release, name_text, address_text and their derived tables), so new vintages can be applied with md_build_ledger()" else "user copy: every table md_compile(), md_lookup() and md_publish() read; the observation ledger is in MATCHDB-full.duckdb",
            tables = tables, sources = sources)
stopifnot(man$matchdb_branch == "main")

jsonlite::write_json(man, out, auto_unbox = TRUE, pretty = TRUE, digits = NA)
cat(readLines(out, n = 14), sep = "\n")
