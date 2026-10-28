# Every table in the user copy matches the full copy in rows and column types.
d <- Sys.getenv("MATCHDB_DATA"); stopifnot(nzchar(d))
con <- DBI::dbConnect(duckdb::duckdb())
DBI::dbExecute(con, sprintf("ATTACH '%s/db/MATCHDB.duckdb' AS f (READ_ONLY)", d))
DBI::dbExecute(con, sprintf("ATTACH '%s/release/MATCHDB_slim.duckdb' AS s (READ_ONLY)", d))
q <- function(x) DBI::dbGetQuery(con, x)
print(q("SELECT database_name, count(*) n FROM duckdb_indexes() GROUP BY 1"))
print(q("SELECT database_name, constraint_type, count(*) n FROM duckdb_constraints() WHERE database_name IN ('f','s') GROUP BY ALL ORDER BY 1,2"))
st <- q("SELECT table_name FROM duckdb_tables() WHERE database_name = 's'")$table_name
bad <- Filter(function(t) {
  a <- q(sprintf('SELECT count(*) n FROM f."%s"', t))$n; b <- q(sprintf('SELECT count(*) n FROM s."%s"', t))$n
  ca <- q(sprintf("SELECT column_name, data_type FROM duckdb_columns() WHERE database_name='f' AND table_name='%s' ORDER BY column_index", t))
  cb <- q(sprintf("SELECT column_name, data_type FROM duckdb_columns() WHERE database_name='s' AND table_name='%s' ORDER BY column_index", t))
  a != b || !identical(ca, cb)
}, st)
cat(length(st), "tables in slim; mismatched:", if (length(bad)) bad else "none", "\n")
DBI::dbDisconnect(con, shutdown = TRUE)
