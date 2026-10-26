# A synthetic BMF, small enough to reason about but shaped like the real one.
# The ingest is otherwise only verified by running it against a 612 MB file,
# which is not a test.

skip_if_no_duckdb <- function() skip_if_not_installed("duckdb")

fake_bmf <- function(path, edit = identity) {
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
  d <- edit(d)
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

## ---- re-ingesting the BMF into a database that already has other sources -------

pin_fake <- function(source, version, local_file) {
  writeLines(c(paste0("source: ", source), paste0("version: ", version),
               "url: http://example.invalid/", paste0("local_file: ", local_file),
               "local_md5: 0", "npmatch_version: 0.0.0.9000",
               "normalize_signature: v1-test"),
             md_path("sources", source, version, "PIN.dcf"))
}

stage_bmf <- function(v, edit = identity) {
  dir.create(md_path("sources", "bmf_unified", v), recursive = TRUE, showWarnings = FALSE)
  fake_bmf(md_path("sources", "bmf_unified", v, "bmf.parquet"), edit)
  pin_fake("bmf_unified", v, "bmf.parquet")
}

# Two years of Schedule I grants. Recipients: ALPHA (in the BMF, written under an
# alias by two filers), GAMMA (in the fake BMF, which the second BMF drops) and
# DELTA (in no BMF, so it enters as filer_only).
stage_schedi <- function(v = "v2_2") {
  dir <- md_path("sources", "schedi", v)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  rows <- data.frame(
    EIN2 = c("EIN-11-1111111", "EIN-22-2222222", "EIN-11-1111111", "EIN-22-2222222"),
    TAX_YEAR = c("2020", "2021", "2021", "2020"),
    SI_02_GRANT_US_ORG_EIN = c("133039601", "133039601", "990000001", "042103594"),
    SI_02_GRANT_US_ORG_NAME_L1 = c("ALPHA TRUST FDN", "Alpha Trust Fdn", "DELTA PROJECT", "GAMMA SOCIETY INC"),
    SI_02_GRANT_US_ORG_NAME_L2 = "",
    SI_02_GRANT_US_ORG_ADDR_L1 = c("1 MAIN ST", "1 MAIN ST", "9 ELM ST", "5 PINE RD"),
    SI_02_GRANT_US_ORG_ADDR_L2 = "",
    SI_02_GRANT_US_ORG_ADDR_CITY = c("CHICAGO", "CHICAGO", "DENVER", "SALEM"),
    SI_02_GRANT_US_ORG_ADDR_STATE = c("IL", "IL", "CO", "OR"),
    SI_02_GRANT_US_ORG_ADDR_ZIP = c("60601", "60601", "80202", "97301"),
    # what the ledger parser keys on; today's ingest ignores them
    OBJECTID = c("o1", "o2", "o3", "o4"), TABLE_ID = "TID-000-000-000",
    RETURN_TIME_STAMP = "2021-06-01T00:00:00",
    stringsAsFactors = FALSE)
  for (yr in unique(rows$TAX_YEAR)) {
    utils::write.csv(rows[rows$TAX_YEAR == yr, ],
                     file.path(dir, sprintf("SI-P02-T01-GRANTS-US-ORGS-GOVTS-%s.CSV", yr)),
                     row.names = FALSE)
  }
  pin_fake("schedi", v, "SI-P02-T01-GRANTS-US-ORGS-GOVTS-2020.CSV")
}

schedi_rows <- function(con) list(
  name = DBI::dbGetQuery(con, "SELECT * FROM name WHERE source = 'schedi' ORDER BY name_id"),
  address = DBI::dbGetQuery(con, "SELECT * FROM address WHERE source = 'schedi' ORDER BY address_id"))

test_that("Schedule I rows survive a BMF re-ingest", {
  skip_if_no_duckdb()
  with_fake_root({
    v <- "v2026-08-11"
    stage_bmf(v)
    stage_schedi()
    md_ingest_bmf(v, validate = FALSE)
    md_ingest_schedi(guard = FALSE)

    con <- md_db(); on.exit(md_db_close(con), add = TRUE)
    before <- schedi_rows(con)
    expect_equal(nrow(before$name), 3)      # ALPHA alias, DELTA, GAMMA
    expect_gt(nrow(before$address), 0)

    counts <- md_ingest_bmf(v, con = con, validate = FALSE)

    # the other source's rows are untouched, ids included
    expect_identical(schedi_rows(con), before)
    # the BMF's own rows are replaced, not duplicated
    expect_equal(unname(counts), c(3, 5, 3))
    n_bmf <- DBI::dbGetQuery(con, "SELECT count(*) n FROM name WHERE source = 'bmf'")$n
    expect_equal(n_bmf, 5)
    # DELTA, entered by Schedule I, is still there
    e <- DBI::dbGetQuery(con, "SELECT ein, layer FROM entity ORDER BY ein")
    expect_equal(nrow(e), 4)
    expect_equal(e$layer[e$ein == "EIN-99-0000001"], "filer_only")
    # and the whole database still validates: unique ids, no orphaned EINs
    expect_no_error(md_validate_bmf(con))
  })
})

test_that("a newer BMF replaces only its own rows", {
  skip_if_no_duckdb()
  with_fake_root({
    stage_bmf("v2026-08-11")
    stage_schedi()
    md_ingest_bmf("v2026-08-11", validate = FALSE)
    md_ingest_schedi(guard = FALSE)

    con <- md_db(); on.exit(md_db_close(con), add = TRUE)
    before <- schedi_rows(con)

    # The next BMF: ALPHA renamed, GAMMA gone, DELTA now listed.
    stage_bmf("v2026-09-11", function(d) {
      d$org_name_raw[d$EIN2 == "EIN-13-3039601"] <- "ALPHA CHARITABLE TRUST"
      d <- d[d$EIN2 != "EIN-04-2103594", ]
      delta <- d[1, ]
      delta$EIN2 <- "EIN-99-0000001"; delta$org_name_raw <- "DELTA PROJECT INC"
      delta$dba_name_raw <- ""; delta$in_care_of_name_raw <- ""
      rbind(d, delta)
    })
    md_ingest_bmf("v2026-09-11", con = con, validate = FALSE)

    expect_identical(schedi_rows(con), before)

    # nothing from the first BMF remains in name or address
    old <- DBI::dbGetQuery(con, "
      SELECT (SELECT count(*) FROM name    WHERE source_vintage = 'bmf_unified-v2026-08-11') +
             (SELECT count(*) FROM address WHERE source_vintage = 'bmf_unified-v2026-08-11') AS n")$n
    expect_equal(old, 0)
    legal <- DBI::dbGetQuery(con, "
      SELECT name_raw FROM name
      WHERE source = 'bmf' AND variant_class = 'legal' AND ein = 'EIN-13-3039601'")$name_raw
    expect_equal(legal, "ALPHA CHARITABLE TRUST")

    e <- DBI::dbGetQuery(con, "SELECT ein, layer, source_vintage FROM entity ORDER BY ein")
    # DELTA's filer_only placeholder gave way to its BMF row
    expect_equal(e$layer[e$ein == "EIN-99-0000001"], "bmf_active")
    expect_equal(sum(e$ein == "EIN-99-0000001"), 1)
    # GAMMA left the BMF but Schedule I still names it, so it stays, as filer_only
    expect_equal(e$layer[e$ein == "EIN-04-2103594"], "filer_only")
    expect_equal(e$source_vintage[e$ein == "EIN-04-2103594"], "schedi-v2_2")
    expect_no_error(md_validate_bmf(con))

    # both loads are on record
    sv <- DBI::dbGetQuery(con, "
      SELECT DISTINCT version FROM source_vintage WHERE source = 'bmf_unified' ORDER BY 1")$version
    expect_equal(sv, c("v2026-08-11", "v2026-09-11"))
  })
})

test_that("an EIN leaving the BMF gets back the layer a fresh build would give it", {
  skip_if_no_duckdb()
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE TABLE entity (ein VARCHAR, layer VARCHAR, active BOOLEAN, source_vintage VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO entity VALUES ('EIN-00-0000009', 'bmf_active', TRUE, 'bmf_unified-v2')")
  refs <- data.frame(
    ein = c("EIN-00-0000001", "EIN-00-0000001", "EIN-00-0000002", "EIN-00-0000004",
            "EIN-00-0000004", "EIN-00-0000005", "EIN-00-0000009"),
    source = c("e_postcard", "schedi", "e_postcard", "e_postcard", "f1023ez",
               "meta_address", "schedi"),
    source_vintage = c("pc-1", "schedi-1", "pc-1", "pc-1", "ez-1", "ma-1", "schedi-1"),
    stringsAsFactors = FALSE)
  DBI::dbWriteTable(con, "name", refs[refs$source != "meta_address", ])
  DBI::dbWriteTable(con, "address", refs[refs$source == "meta_address", ])
  DBI::dbWriteTable(con, "entity_event", data.frame(
    ein = "EIN-00-0000003", source = "revocations", source_vintage = "rv-1"))

  expect_equal(matchdb:::.md_restore_unlisted_entities(con), 5)
  e <- DBI::dbGetQuery(con, "SELECT ein, layer, source_vintage FROM entity ORDER BY ein")
  expect_equal(e$layer, c("filer_only",     # 990 schedule beats e-Postcard
                          "postcard_only",
                          "revoked_only",   # found through entity_event
                          "approved_only",  # 1023-EZ is built first
                          "filer_only",     # unlisted source falls back
                          "bmf_active"))    # already present: untouched
  expect_equal(e$source_vintage[1], "schedi-1")
})

test_that("Schedule I groups accent and ampersand variants as one name", {
  skip_if_no_duckdb()
  skip_if_not_installed("stringi")
  with_fake_root({
    stage_bmf("v2026-08-11")
    dir <- md_path("sources", "schedi", "v2_2")
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    rows <- data.frame(
      EIN2 = c("EIN-11-1111111", "EIN-22-2222222", "EIN-33-3333333", "EIN-11-1111111", "EIN-22-2222222"),
      TAX_YEAR = "2020", SI_02_GRANT_US_ORG_EIN = "133039601",
      SI_02_GRANT_US_ORG_NAME_L1 = c("Café Alpha & Sons", "Cafe Alpha and Sons", "CAFE ALPHA AND SONS",
                                     "Øresund Trust", "Oresund Trust"),
      SI_02_GRANT_US_ORG_NAME_L2 = "", SI_02_GRANT_US_ORG_ADDR_L1 = "1 MAIN ST",
      SI_02_GRANT_US_ORG_ADDR_L2 = "", SI_02_GRANT_US_ORG_ADDR_CITY = "CHICAGO",
      SI_02_GRANT_US_ORG_ADDR_STATE = "IL", SI_02_GRANT_US_ORG_ADDR_ZIP = "60601",
      stringsAsFactors = FALSE)
    utils::write.csv(rows, file.path(dir, "SI-P02-T01-GRANTS-US-ORGS-GOVTS-2020.CSV"),
                     row.names = FALSE, fileEncoding = "UTF-8")
    pin_fake("schedi", "v2_2", "SI-P02-T01-GRANTS-US-ORGS-GOVTS-2020.CSV")
    md_ingest_bmf("v2026-08-11", validate = FALSE)
    md_ingest_schedi(guard = FALSE)
    con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE)
    n <- DBI::dbGetQuery(con, "
      SELECT n_corroborators FROM name WHERE source = 'schedi' ORDER BY n_corroborators DESC")
    # three filers wrote one name three ways, two wrote another two ways
    expect_equal(n$n_corroborators, c(3, 2))
  })
})

## ---- Phase 5 step 6: the ledger reproduces today's name and address tables ----

test_that("rollups from the ledger reproduce what today's BMF and Schedule I ingests write", {
  skip_if_no_duckdb()
  skip_if_not_installed("digest")
  skip_if_not_installed("stringi")
  with_fake_root({
    v <- "v2026-08-11"
    stage_bmf(v)
    stage_schedi()
    md_ingest_bmf(v, validate = FALSE)
    md_ingest_schedi(guard = FALSE)

    con <- md_db(); on.exit(md_db_close(con), add = TRUE)
    # the same files, through the ledger
    bmf <- sprintf("read_parquet('%s')",
                   gsub("\\\\", "/", md_path("sources", "bmf_unified", v, "bmf.parquet")))
    suppressMessages(md_apply_release(con, md_parse_bmf_unified(con, bmf), "bmf_unified", v))
    for (yr in c("2020", "2021")) {
      f <- md_path("sources", "schedi", "v2_2", sprintf("SI-P02-T01-GRANTS-US-ORGS-GOVTS-%s.CSV", yr))
      rel <- sprintf("read_csv('%s', all_varchar = true)", gsub("\\\\", "/", f))
      suppressMessages(md_apply_release(con, md_parse_schedi(con, rel), "schedi", "v2_2", part = yr))
    }
    suppressMessages(md_build_rollups(con))

    cols <- "ein, source, variant_class, name_raw, n_obs, n_corroborators, first_year, last_year"
    today <- DBI::dbGetQuery(con, sprintf("SELECT %s FROM name ORDER BY ALL", cols))
    rolled <- DBI::dbGetQuery(con, sprintf("SELECT %s FROM rollup_name ORDER BY ALL", cols))
    expect_equal(rolled, today, ignore_attr = TRUE)

    acols <- "ein, source, variant_class, street_raw, city_raw, state, zip5, n_obs, first_vintage, last_vintage"
    today_a <- DBI::dbGetQuery(con, sprintf("SELECT %s FROM address ORDER BY ALL", acols))
    rolled_a <- DBI::dbGetQuery(con, sprintf("SELECT %s FROM rollup_address ORDER BY ALL", acols))
    expect_equal(rolled_a, today_a, ignore_attr = TRUE)

    # observed addresses are paired with the observed name they were written with
    pairs <- DBI::dbGetQuery(con, "
      SELECT a.ein, n.name_raw FROM rollup_address a JOIN rollup_name n USING (name_id)
      WHERE a.variant_class = 'observed' ORDER BY 1")
    expect_equal(nrow(pairs), nrow(DBI::dbGetQuery(con,
      "SELECT * FROM rollup_address WHERE variant_class = 'observed'")))

    cmp <- md_compare_rollups(con)
    expect_true(all(cmp$pct_live_matched == 100 & cmp$pct_rollup_matched == 100))
  })
})
