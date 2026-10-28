# The user copy: every table but the observation ledger, which only maintainer
# code reads (md-identity, md-ledger, md-normalizer-diff, md-rollup, md-text).
d <- Sys.getenv("MATCHDB_DATA"); stopifnot(nzchar(d))
src <- file.path(d, "db", "MATCHDB.duckdb"); out <- file.path(d, "release", "MATCHDB_slim.duckdb"); unlink(out)
ledger <- c("obs", "release", "name_text", "address_text", "name_text_derived", "address_text_derived")
con <- DBI::dbConnect(duckdb::duckdb(), out)
DBI::dbExecute(con, sprintf("ATTACH '%s' AS src (READ_ONLY)", src))
t <- setdiff(DBI::dbGetQuery(con, "SELECT table_name FROM duckdb_tables() WHERE database_name='src'")$table_name, ledger)
for (x in t) DBI::dbExecute(con, sprintf('CREATE TABLE "%s" AS SELECT * FROM src."%s"', x, x))
DBI::dbExecute(con, "DETACH src"); DBI::dbExecute(con, "CHECKPOINT"); DBI::dbDisconnect(con, shutdown = TRUE)
cat(sprintf("slim: %d tables, %.2f GB\n", length(t), file.size(out) / 1e9))
