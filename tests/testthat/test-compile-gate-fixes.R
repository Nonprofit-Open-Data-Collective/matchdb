# Two rules the Phase 1 gate found missing. A DBA that normalizes like the
# legal name (THE ELLSWORTH GARDEN CLUB / ELLSWORTH GARDEN CLUB) must not lend
# the legal row its spelling; and an address with no street but a ZIP is still
# a place, as pfmatch's reference keeps it.

gate_db <- function() {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb())
  x <- function(sql) DBI::dbExecute(con, sql)
  x(sprintf("CREATE TABLE entity AS SELECT * FROM (VALUES ('%s','bmf_active',TRUE),
             ('%s','bmf_active',TRUE)) v(ein, layer, active)", e(1), e(2)))
  DBI::dbWriteTable(con, "name", data.frame(
    name_id = 1:3, ein = e(c(1, 1, 2)),
    name_raw = c("THE ELLSWORTH GARDEN CLUB", "ELLSWORTH GARDEN CLUB", "ZETA CLUB"),
    variant_class = c("legal", "dba", "legal"), source = "bmf", source_vintage = "t",
    n_obs = NA_integer_, n_corroborators = NA_integer_, first_year = NA_integer_,
    last_year = NA_integer_, stringsAsFactors = FALSE))
  DBI::dbWriteTable(con, "address", data.frame(
    address_id = 1:2, ein = e(c(1, 2)), name_id = NA_integer_,
    street_raw = c("1 MAIN ST", NA), city_raw = c("ELLSWORTH", "OGDEN"), state = "ME",
    zip5 = c("04605", "04606"), zip_plus4 = "", county = "", variant_class = "mailing",
    source = "bmf", n_obs = 1L, last_vintage = NA_character_, stringsAsFactors = FALSE))
  suppressMessages(md_build_derived(con, chunk = 4L))
  x("CREATE TABLE source_vintage (vintage_id VARCHAR, local_md5 VARCHAR, row_count INTEGER)")
  x("INSERT INTO source_vintage VALUES ('bmf_unified-t:entity', 'abc', 2)")
  suppressMessages(md_build_compact(con, what = "name"))
  suppressMessages(md_build_stats(con))
  con
}

test_that("the legal row keeps its own spelling when a DBA shares its key", {
  con <- gate_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  nk <- DBI::dbGetQuery(con, "SELECT name_key FROM name_derived ORDER BY name_id")$name_key
  skip_if(nk[1] != nk[2], "the normalizer no longer joins these two names")
  ref <- ref_of(con, layers = "bmf_active", names = c("legal", "dba"),
                addresses = "mailing", sources = "bmf")$reference
  r1 <- ref[ref$.ein == e(1), ]
  expect_equal(nrow(r1), 1L)
  expect_equal(r1$name, "THE ELLSWORTH GARDEN CLUB")
  nc <- DBI::dbGetQuery(con, sprintf("SELECT name_raw FROM name_compact WHERE ein = '%s'", e(1)))
  expect_equal(nc$name_raw, "THE ELLSWORTH GARDEN CLUB")
})

test_that("an address with a ZIP but no street is kept", {
  con <- gate_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ref <- ref_of(con, layers = "bmf_active", names = "legal", addresses = "mailing",
                sources = "bmf")$reference
  r2 <- ref[ref$.ein == e(2), ]
  expect_equal(nrow(r2), 1L)
  expect_equal(r2$zip5, "04606")
  expect_equal(r2$street_key, "")
})
