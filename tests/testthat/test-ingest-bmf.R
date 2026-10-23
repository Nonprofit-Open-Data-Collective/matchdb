# A synthetic BMF, small enough to reason about but shaped like the real one.
# The ingest is otherwise only verified by running it against a 612 MB file,
# which is not a test.

skip_if_no_duckdb <- function() skip_if_not_installed("duckdb")

fake_bmf <- function(path) {
  d <- data.frame(
    EIN2 = c("EIN-13-3039601", "EIN-53-0196605", "EIN-04-2103594"),
    org_name_raw = c("ALPHA TRUST", "BETA FUND INC", "GAMMA SOCIETY"),
    dba_name_raw = c("ALPHA", "", NA),
    in_care_of_name_raw = c("", "% TREASURER", NA),
    org_addr_street_raw = c("1 MAIN ST", "2 OAK AVE", ""),
    org_addr_city_raw = c("CHICAGO", "BOSTON", "NOWHERE"),
    org_addr_state = c("IL", "MA", "XX"),
    org_addr_zip5 = c("60601", "02108", "00000"),
    org_addr_zip4 = c("1234", "", ""),
    org_addr_is_po_box = c(FALSE, FALSE, FALSE),
    first_vintage_ym = c("2020-01", "2019-05", "2001-03"),
    last_vintage_ym = c("2026-07", "2026-07", "2005-06"),
    bmf_vintages_observed = c("30", "40", "9"),
    ruling_date = c("1990-01-01", "1985-06-01", "1970-02-01"),
    bmf_source = c("current", "current", "legacy"),
    status_code = c("1", "1", NA),
    subsection_code = c("03", "03", "04"),
    foundation_code = c("15", "16", "10"),
    affiliation_code = c("3", "3", "1"),
    group_exemption_number = c("0000", "0000", "1234"),
    group_exemption_is_member = c(FALSE, FALSE, TRUE),
    ntee_code_raw = c("B11", "E20", ""),
    geo_lat = c(41.9, 42.4, NA), geo_lon = c(-87.6, -71.1, NA),
    geo_county = c("Cook", "Suffolk", NA),
    geo_metro_area = c("Chicago", "Boston", NA),
    stringsAsFactors = FALSE
  )
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "d", d)
  DBI::dbExecute(con, sprintf("COPY d TO '%s' (FORMAT PARQUET)",
                              gsub("\\\\", "/", path)))
  path
}

with_fake_root <- function(code) {
  root <- tempfile("mdroot"); dir.create(root)
  old <- Sys.getenv("MATCHDB_DATA", unset = NA)
  Sys.setenv(MATCHDB_DATA = root)
  on.exit({
    if (is.na(old)) Sys.unsetenv("MATCHDB_DATA") else Sys.setenv(MATCHDB_DATA = old)
    unlink(root, recursive = TRUE)
  })
  force(code)
}

test_that("the BMF ingest produces the three tables with the right shape", {
  skip_if_no_duckdb()
  with_fake_root({
    v <- "v2026-08-11"
    dir.create(md_path("sources", "bmf_unified", v), recursive = TRUE)
    pq <- md_path("sources", "bmf_unified", v, "bmf.parquet")
    fake_bmf(pq)
    writeLines(c("source: bmf_unified", paste0("version: ", v),
                 "url: http://example.invalid/bmf.parquet",
                 "local_file: bmf.parquet", "local_md5: 0",
                 "npmatch_version: 0.0.0.9000",
                 "normalize_signature: v1-test"),
               md_path("sources", "bmf_unified", v, "PIN.dcf"))

    counts <- md_ingest_bmf(v, validate = FALSE)
    expect_equal(unname(counts[["entity"]]), 3L)
    # legal x3 + dba x1 + in_care_of x1; blanks and NAs must not become rows
    expect_equal(unname(counts[["name"]]), 5L)
    # the org with an empty street still has a city, state and ZIP: a place
    expect_equal(unname(counts[["address"]]), 3L)

    con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE)
    e <- DBI::dbGetQuery(con, "SELECT ein, layer, active FROM entity ORDER BY ein")
    # ordered by ein: 04-... is the legacy row, then the two current ones
    expect_equal(e$layer, c("bmf_inactive", "bmf_active", "bmf_active"))
    expect_equal(e$active, c(FALSE, TRUE, TRUE))

    vc <- DBI::dbGetQuery(con, "SELECT variant_class, count(*) n FROM name GROUP BY 1 ORDER BY 1")
    expect_equal(vc$variant_class, c("dba", "in_care_of", "legal"))
    expect_equal(vc$n, c(1, 1, 3))
  })
})

test_that("an unpinned source refuses to ingest", {
  skip_if_no_duckdb()
  with_fake_root({
    expect_error(md_ingest_bmf("v-nope"), "not pinned")
  })
})

test_that("every ingested row is traceable to a source_vintage", {
  skip_if_no_duckdb()
  with_fake_root({
    v <- "v2026-08-11"
    dir.create(md_path("sources", "bmf_unified", v), recursive = TRUE)
    fake_bmf(md_path("sources", "bmf_unified", v, "bmf.parquet"))
    writeLines(c("source: bmf_unified", paste0("version: ", v),
                 "url: http://example.invalid/bmf.parquet",
                 "local_file: bmf.parquet", "local_md5: abc123",
                 "npmatch_version: 0.0.0.9000",
                 "normalize_signature: v1-test"),
               md_path("sources", "bmf_unified", v, "PIN.dcf"))
    md_ingest_bmf(v, validate = FALSE)

    con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE)
    sv <- DBI::dbGetQuery(con, "SELECT table_name, local_md5 FROM source_vintage ORDER BY table_name")
    expect_setequal(sv$table_name, c("address", "entity", "name"))
    expect_true(all(sv$local_md5 == "abc123"))
    orphan <- DBI::dbGetQuery(con, "SELECT count(*) n FROM name WHERE source_vintage IS NULL")$n
    expect_equal(orphan, 0)
  })
})
