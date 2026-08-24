# The bug this guards against: an idempotent ingest re-run reassigns fresh
# name_id/address_id values, so name_derived's join silently matches fewer
# rows every time a source is re-ingested -- no error, just quietly missing
# data downstream. Found in dev/COMPACTION.md's first real run.

setup_db <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbExecute(con, "CREATE TABLE name (name_id BIGINT, ein VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE address (address_id BIGINT, ein VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO name VALUES (1,'EIN-00-0000001'), (2,'EIN-00-0000002')")
  DBI::dbExecute(con, "INSERT INTO address VALUES (1,'EIN-00-0000001')")
  con
}

test_that("a fresh derived table reports no orphans and does not error", {
  skip_if_not_installed("duckdb")
  con <- setup_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE TABLE name_derived (name_id BIGINT, name_key VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO name_derived VALUES (1,'A'), (2,'B')")
  DBI::dbExecute(con, "CREATE TABLE address_derived (address_id BIGINT, street_key VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO address_derived VALUES (1,'X')")

  out <- md_check_derived_fresh(con)
  expect_equal(out$orphaned_rows, c(0, 0))
})

test_that("a stale name_derived (reassigned ids) is caught, not silently under-joined", {
  skip_if_not_installed("duckdb")
  con <- setup_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # simulate a re-ingest: name now holds ids 3-4, but name_derived still has 1-2
  DBI::dbExecute(con, "DELETE FROM name")
  DBI::dbExecute(con, "INSERT INTO name VALUES (3,'EIN-00-0000001'), (4,'EIN-00-0000002')")
  DBI::dbExecute(con, "CREATE TABLE name_derived (name_id BIGINT, name_key VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO name_derived VALUES (1,'A'), (2,'B')")
  DBI::dbExecute(con, "CREATE TABLE address_derived (address_id BIGINT, street_key VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO address_derived VALUES (1,'X')")

  expect_error(md_check_derived_fresh(con), "stale")
  expect_warning(out <- md_check_derived_fresh(con, stop_on_stale = FALSE), "stale")
  expect_equal(out$orphaned_rows[out$table == "name"], 2)
})
