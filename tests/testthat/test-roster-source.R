# The group-roster ingests read either the published e-file tables (v2_3 on)
# or the older derived extract. Both must yield the same five columns, and the
# published tables must win when both are present.

roster_rows <- function(con, sql) {
  DBI::dbGetQuery(con, sprintf(
    "SELECT filer_ein, member_ein, member_name1, member_name2, tax_year FROM %s
     ORDER BY tax_year, member_ein", sql))
}

with_root <- function(code) {
  root <- tempfile("mdroot"); dir.create(root)
  old <- Sys.getenv("MATCHDB_DATA", unset = NA)
  Sys.setenv(MATCHDB_DATA = root)
  on.exit({
    if (is.na(old)) Sys.unsetenv("MATCHDB_DATA") else Sys.setenv(MATCHDB_DATA = old)
    unlink(root, recursive = TRUE)
  })
  force(code)
}

test_that("published tables are read across years and mapped to the roster columns", {
  skip_if_not_installed("duckdb")
  with_root({
    d <- md_path("sources", "efile_affiliate_listing", "v3_1", create = TRUE)
    hdr <- "EIN2,ORG_EIN,TAX_YEAR,F9_00_AFFIL_EIN,F9_00_AFFIL_NAME_L1,F9_00_AFFIL_NAME_L2"
    writeLines(c(hdr, 'EIN-01-0000001,010000001,2015,020000002,"LODGE, NO. 5",'),
               file.path(d, "F9-P00-T01-AFFILIATE-LISTING-2015.CSV"))
    writeLines(c(hdr, "EIN-01-0000001,010000001,2025,020000003,CHAPTER,EAST"),
               file.path(d, "F9-P00-T01-AFFILIATE-LISTING-2025.CSV"))
    # an extract beside the tables must be ignored
    writeLines("filer_ein,member_ein,member_name1,member_name2,tax_year",
               file.path(d, "affiliate-listing-2009-2013.csv"))

    sql <- .md_roster_source("efile_affiliate_listing", "v3_1", NULL,
      table = "F9-P00-T01-AFFILIATE-LISTING",
      extract = "affiliate-listing-2009-2013.csv",
      cols = c(member_ein = "F9_00_AFFIL_EIN", member_name1 = "F9_00_AFFIL_NAME_L1",
               member_name2 = "F9_00_AFFIL_NAME_L2"))
    con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
    got <- roster_rows(con, sql)

    expect_equal(got$tax_year, c("2015", "2025"))
    expect_equal(got$filer_ein, c("010000001", "010000001"))
    expect_equal(got$member_ein, c("020000002", "020000003"))
    # a quoted comma stays inside the name
    expect_equal(got$member_name1, c("LODGE, NO. 5", "CHAPTER"))
    expect_equal(got$member_name2, c(NA, "EAST"))
  })
})

test_that("a table with no second name line gives NULL member_name2", {
  skip_if_not_installed("duckdb")
  with_root({
    d <- md_path("sources", "efile_sched_c_affil", "v3_1", create = TRUE)
    writeLines(c("ORG_EIN,TAX_YEAR,SC_02_AFFIL_EIN,SC_02_AFFIL_NAME_L1",
                 "010000001,2020,020000002,HEALTH SYSTEM"),
               file.path(d, "SC-P02-T01-AFFILIATED-GROUP-2020.CSV"))
    sql <- .md_roster_source("efile_sched_c_affil", "v3_1", NULL,
      table = "SC-P02-T01-AFFILIATED-GROUP",
      extract = "sched-c-affiliated-group-2009-2013.csv",
      cols = c(member_ein = "SC_02_AFFIL_EIN", member_name1 = "SC_02_AFFIL_NAME_L1"))
    con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
    got <- roster_rows(con, sql)
    expect_equal(got$member_name1, "HEALTH SYSTEM")
    expect_true(is.na(got$member_name2))
  })
})

test_that("without published tables the old extract is read", {
  skip_if_not_installed("duckdb")
  with_root({
    d <- md_path("sources", "efile_affiliate_listing", "v2009-2013", create = TRUE)
    writeLines(c("filer_ein,member_ein,member_name1,member_name2,tax_year",
                 "010000001,020000002,POST 7,,2012"),
               file.path(d, "affiliate-listing-2009-2013.csv"))
    sql <- .md_roster_source("efile_affiliate_listing", "v2009-2013", NULL,
      table = "F9-P00-T01-AFFILIATE-LISTING",
      extract = "affiliate-listing-2009-2013.csv",
      cols = c(member_ein = "F9_00_AFFIL_EIN", member_name1 = "F9_00_AFFIL_NAME_L1"))
    con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
    got <- roster_rows(con, sql)
    expect_equal(got$member_name1, "POST 7")
    expect_equal(got$tax_year, "2012")
  })
})

test_that("an empty version directory is an error that names both inputs", {
  with_root({
    md_path("sources", "efile_sched_c_affil", "v3_1", create = TRUE)
    expect_error(
      .md_roster_source("efile_sched_c_affil", "v3_1", NULL,
        table = "SC-P02-T01-AFFILIATED-GROUP",
        extract = "sched-c-affiliated-group-2009-2013.csv",
        cols = c(member_ein = "SC_02_AFFIL_EIN", member_name1 = "SC_02_AFFIL_NAME_L1")),
      "SC-P02-T01-AFFILIATED-GROUP-\\*.CSV nor sched-c-affiliated-group")
  })
})
