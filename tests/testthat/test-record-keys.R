# Phase 5 step 2: the natural key of each source (dev/IDENTITY.md section 8).

test_that("every source has a natural key", {
  k <- md_record_keys()
  expect_setequal(k$source, md_sources()$source)
  expect_false(any(is.na(k$filing_key)))
  expect_true(all(k$grain %in% c("record", "row")))
  expect_true(all(!is.na(k$evidence) & nzchar(k$evidence)))
})

test_that("multi-row e-file tables key on content, not on TABLE_ID", {
  k <- md_record_keys()
  rows <- k[k$grain == "row" & k$filing_key == "OBJECTID", ]
  expect_true(all(rows$trace_key == "TABLE_ID"))
  # every third-party e-file table names its filer and the field that picks the latest return
  ment <- k[k$kind == "mentions" & k$filing_key == "OBJECTID", ]
  expect_true(all(ment$asserted_by == "EIN2"))
  expect_true(all(ment$latest_by == "RETURN_TIME_STAMP"))
})

test_that("a repeated record key fails the check", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "hdr", data.frame(OBJECTID = c("1", "2", "2"), EIN2 = "EIN-00-0000001"))
  r <- md_check_record_key(con, "hdr", "efile_header")
  expect_false(r$ok)
  expect_equal(r$n_repeats, 1)
})

test_that("identical rows in one return are counted, not failed", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # two identical grants in filing 1 (only TABLE_ID differs), one other grant
  DBI::dbWriteTable(con, "si", data.frame(
    OBJECTID = c("1", "1", "1"), TABLE_ID = c("TID-0", "TID-1", "TID-2"),
    EIN2 = "EIN-11-1111111", GRANTEE = c("ALPHA", "ALPHA", "BETA"), AMOUNT = c("500", "500", "900")))
  r <- md_check_record_key(con, "si", "schedi")
  expect_true(r$ok)
  expect_equal(c(r$n_rows, r$n_keys, r$n_repeats), c(3, 2, 1))
})

test_that("a missing key column is an error, not a pass", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "x", data.frame(EIN = "1"))
  expect_error(md_check_record_key(con, "x", "irs527"), "FORM_ID_NUMBER")
  expect_error(md_check_record_key(con, "x", "nope"), "unknown source")
})
