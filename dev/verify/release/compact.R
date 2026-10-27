# Drop the legacy tables, then copy the database into a fresh file (DuckDB
# does not give space back on DROP). The old file is kept beside it as
# MATCHDB.precompact.duckdb until the upload is done.
a <- commandArgs(TRUE)
db <- if (length(a)) a[1] else file.path(Sys.getenv("MATCHDB_DATA"), "db", "MATCHDB.duckdb")
new <- file.path(dirname(db), "MATCHDB_compact.duckdb")
old <- file.path(dirname(db), "MATCHDB.precompact.duckdb")
stopifnot(file.exists(db), !file.exists(old)); unlink(new)
con <- DBI::dbConnect(duckdb::duckdb(), db)
for (t in c("name_legacy", "address_legacy")) DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s", t))
left <- grep("^(rollup_|cp_|frame_t)", DBI::dbListTables(con), value = TRUE)
if (length(left)) stop("working tables left: ", paste(left, collapse = ", "))
counts <- function(con, cat) {
  t <- DBI::dbGetQuery(con, sprintf("SELECT table_name FROM duckdb_tables() WHERE database_name = '%s' AND NOT temporary ORDER BY 1", cat))$table_name
  setNames(vapply(t, function(x) as.numeric(DBI::dbGetQuery(con, sprintf('SELECT count(*) n FROM "%s"."%s"', cat, x))$n), 0), t)
}
before <- counts(con, sub("[.]duckdb$", "", basename(db)))
DBI::dbExecute(con, "CHECKPOINT"); DBI::dbDisconnect(con, shutdown = TRUE)

con <- DBI::dbConnect(duckdb::duckdb(), new)
DBI::dbExecute(con, sprintf("ATTACH '%s' AS src (READ_ONLY)", db))
DBI::dbExecute(con, "COPY FROM DATABASE src TO MATCHDB_compact")
after <- counts(con, "MATCHDB_compact")
objs <- function(cat) DBI::dbGetQuery(con, sprintf("
  SELECT 'view' k, view_name n FROM duckdb_views() WHERE database_name = '%s' AND NOT internal
  UNION ALL SELECT 'macro', function_name FROM duckdb_functions() WHERE database_name = '%s' AND NOT internal
  ORDER BY 1, 2", cat, cat))
ov <- objs("src"); nv <- objs("MATCHDB_compact")
DBI::dbExecute(con, "DETACH src"); DBI::dbExecute(con, "CHECKPOINT")
DBI::dbDisconnect(con, shutdown = TRUE)
stopifnot(identical(names(before), names(after)), all(before == after), identical(ov, nv))
cat(sprintf("tables %d, views/macros %d, rows identical\n", length(after), nrow(nv)))
cat(sprintf("before %.2f GB, after %.2f GB\n", file.size(db) / 1e9, file.size(new) / 1e9))
stopifnot(file.rename(db, old), file.rename(new, db))
print(data.frame(table = names(after), rows = after, row.names = NULL))
