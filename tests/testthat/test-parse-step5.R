# Phase 5 step 5: parsers for the remaining sources that write names or
# addresses (dev/IDENTITY.md section 8). Each fixture uses the publisher's own
# column names; each test applies the frame and checks what the ledger holds.

skip_if_no_parse_deps <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("digest")
  skip_if_not_installed("stringi")
}

parse_con <- function() DBI::dbConnect(duckdb::duckdb())

apply_raw <- function(con, raw, parse, source, version, ...) {
  DBI::dbWriteTable(con, "raw_t", raw, overwrite = TRUE)
  args <- list(...)
  pargs <- args[names(args) %in% "year"]
  aargs <- args[!names(args) %in% "year"]
  frame <- do.call(parse, c(list(con, "raw_t"), pargs))
  suppressMessages(do.call(md_apply_release, c(list(con, frame, source, version), aargs)))
}

obs_of <- function(con, source) DBI::dbGetQuery(con, sprintf("
  SELECT o.*, n.name_raw, a.street_raw, a.zip5, a.zip_plus4
  FROM obs o LEFT JOIN name_text n USING (name_text_id)
  LEFT JOIN address_text a USING (address_text_id)
  WHERE o.source = '%s' AND o.retracted_in IS NULL ORDER BY o.role, n.name_raw", source))

test_that("bmf_unified loads as a seed with envelope bounds", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  raw <- data.frame(
    EIN2 = c("EIN-13-3039601", "EIN-04-2103594"), org_name_raw = c("ALPHA TRUST", "GAMMA SOCIETY"),
    dba_name_raw = c("ALPHA", NA), in_care_of_name_raw = c("", "% TREASURER"),
    org_addr_street_raw = c("1 MAIN ST", ""), org_addr_city_raw = c("CHICAGO", ""),
    org_addr_state = c("IL", ""), org_addr_zip5 = c("60601", ""), org_addr_zip4 = c("1234", ""),
    first_vintage_ym = c("2020-01", "2001-03"), last_vintage_ym = c("2026-07", "2005-06"),
    stringsAsFactors = FALSE)
  r <- apply_raw(con, raw, md_parse_bmf_unified, "bmf_unified", "v2026-08-11")
  expect_equal(r$n_new, 5)   # 2 legal + 1 dba + 1 in care of + 1 address (GAMMA has none)
  o <- obs_of(con, "bmf_unified")
  expect_true(all(o$bounds_kind == "envelope"))
  expect_equal(o$first_seen[o$name_raw %in% "GAMMA SOCIETY"], "2001-03")
  expect_equal(o$zip_plus4[o$role == "mailing"], "1234")
})

test_that("a 1023-EZ year file is one partition, keyed on the EIN", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  raw <- data.frame(Ein = c("133039601", "53-0196605", "bad"), Orgname1 = c("ALPHA", "BETA FUND", "X"),
                    Orgname2 = c("TRUST", "", ""), Address = c("1 MAIN ST", "2 OAK AVE", ""),
                    City = c("CHICAGO", "BOSTON", ""), State = c("IL", "MA", ""),
                    Zip = c("60601", "021081234", ""), Zippl4 = c("1234", "", ""),
                    stringsAsFactors = FALSE)
  r <- apply_raw(con, raw, md_parse_f1023ez, "f1023ez", "v1", part = 2022, year = 2022)
  expect_equal(r$n_new, 2)    # "bad" is no EIN
  o <- obs_of(con, "f1023ez")
  expect_setequal(o$name_raw, c("ALPHA TRUST", "BETA FUND"))
  expect_true(all(o$period == 2022))
  expect_setequal(o$zip_plus4, c("1234", "1234"))   # from Zippl4, and from a nine-digit Zip
})

test_that("Schedule R Part II rows are mentions by the filer", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  raw <- data.frame(
    EIN2 = "EIN-11-1111111", OBJECTID = "501", TABLE_ID = c("TID-1", "TID-2", "TID-3"),
    TAX_YEAR = "2022", RETURN_TIME_STAMP = "2023-05-01",
    SR_02_RLTD_ORG_EIN = c("133039601", "53-0196605", ""),
    SR_02_RLTD_ORG_NAME_L1 = c("ALPHA TRUST", "BETA FUND", "NO EIN ORG"), SR_02_RLTD_ORG_NAME_L2 = "",
    SR_02_RLTD_ORG_ADDR_L1 = "1 MAIN ST", SR_02_RLTD_ORG_ADDR_L2 = "",
    SR_02_RLTD_ORG_ADDR_CITY = "CHICAGO", SR_02_RLTD_ORG_ADDR_STATE = "IL",
    SR_02_RLTD_ORG_ADDR_ZIP = "60601", stringsAsFactors = FALSE)
  r <- apply_raw(con, raw, md_parse_efile_related, "efile_related", "v3_1", part = 2022)
  expect_equal(r$n_new, 2)    # a related organisation without an EIN is not an observation of one
  o <- obs_of(con, "efile_related")
  expect_true(all(o$asserted_by == "EIN-11-1111111" & o$role == "observed"))
  expect_setequal(o$trace_key, c("TID-1", "TID-2"))
})

test_that("an affiliate listing keeps the subordinate's own name and address", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  raw <- data.frame(
    EIN2 = "EIN-22-2222222", ORG_EIN = "222222222", OBJECTID = "601",
    TABLE_ID = c("TID-0", "TID-1", "TID-2", "TID-3"), TAX_YEAR = "2022", RETURN_TIME_STAMP = "2023-05-01",
    F9_00_AFFIL_EIN = c("133039601", "530196605", "222222222", "1234"),
    F9_00_AFFIL_NAME_L1 = c("ALPHA LODGE 12", "BETA LODGE 7", "THE PARENT", "SHORT EIN"),
    F9_00_AFFIL_NAME_L2 = "", F9_00_AFFIL_ADDR_L1 = c("1 MAIN ST", "", "9 HQ RD", "1 X ST"),
    F9_00_AFFIL_ADDR_L2 = "", F9_00_AFFIL_ADDR_CITY = c("CHICAGO", "", "DC", "Y"),
    F9_00_AFFIL_ADDR_STATE = c("IL", "", "DC", "Z"), F9_00_AFFIL_ADDR_ZIP = c("60601", "", "20001", "1"),
    stringsAsFactors = FALSE)
  r <- apply_raw(con, raw, md_parse_affiliate_listing, "efile_affiliate_listing", "v3_1", part = 2022)
  # the parent listing itself and the four-digit member EIN are dropped
  expect_equal(r$n_new, 2)
  o <- obs_of(con, "efile_affiliate_listing")
  expect_setequal(o$name_raw, c("ALPHA LODGE 12", "BETA LODGE 7"))
  expect_true(all(o$asserted_by == "EIN-22-2222222"))
  expect_equal(sum(!is.na(o$address_text_id)), 1)   # BETA's address is blank
})

test_that("the affiliate listing parser reads the older extract without addresses", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  raw <- data.frame(EIN2 = "EIN-22-2222222", OBJECTID = "601", TABLE_ID = "TID-0", TAX_YEAR = "2012",
                    RETURN_TIME_STAMP = "2013-05-01", F9_00_AFFIL_EIN = "133039601",
                    F9_00_AFFIL_NAME_L1 = "ALPHA LODGE 12", F9_00_AFFIL_NAME_L2 = "",
                    stringsAsFactors = FALSE)
  r <- apply_raw(con, raw, md_parse_affiliate_listing, "efile_affiliate_listing", "v2009-2013", part = 2012)
  expect_equal(r$n_new, 1)
})

test_that("the e-Postcard is a snapshot: names and address as separate spells", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  pc <- function(legal) data.frame(
    ein = "133039601", tax_year = "2024", legal_name = legal, dba_name_1 = "ALPHA",
    dba_name_2 = "", dba_name_3 = NA, organization_address_line_1 = "1 MAIN ST",
    organization_city = "CHICAGO", organization_state = "IL", organization_zip = "60601-1234",
    stringsAsFactors = FALSE)
  r <- apply_raw(con, pc("ALPHA TRUST"), md_parse_e_postcard, "e_postcard", "v2026-07", vintage = "2026-07")
  expect_equal(r$n_new, 3)    # legal, one dba, address
  # renamed next month, same address: the address spell continues
  r <- apply_raw(con, pc("ALPHA TRUST INC"), md_parse_e_postcard, "e_postcard", "v2026-08", vintage = "2026-08")
  expect_equal(c(r$n_new, r$n_kept), c(1, 2))
  o <- DBI::dbGetQuery(con, "SELECT role, first_seen, last_seen FROM obs WHERE role = 'mailing'")
  expect_equal(c(o$first_seen, o$last_seen), c("2026-07", "2026-08"))
})

test_that("revocations key on EIN and date, and a second revocation is a second record", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  raw <- data.frame(
    ein = c("133039601", "133039601", "530196605"), legal_name = c("ALPHA TRUST", "ALPHA TRUST", "BETA FUND"),
    doing_business_as_name = c("", "", "BETA"), organization_address = "1 MAIN ST", city = "CHICAGO",
    state = "IL", zip_code = c("60601", "60601", "021081234"),
    revocation_date = c("15-May-2011", "15-May-2018", "15-Nov-2010"),
    revocation_posting_date = "", exemption_reinstatement_date = c("01-Jan-2014", "", ""),
    stringsAsFactors = FALSE)
  r <- apply_raw(con, raw, md_parse_revocations, "revocations", "v2026-07")
  expect_equal(r$n_new, 4)    # two revocations of ALPHA, BETA's legal name and dba
  o <- obs_of(con, "revocations")
  expect_setequal(o$period, c(2011, 2018, 2010, 2010))
  expect_equal(sum(o$record_key == "EIN-13-3039601 2011-05-15"), 1)
  # the next month's cumulative list adds a revocation and keeps the rest
  raw2 <- rbind(raw, transform(raw[3, ], ein = "042103594", legal_name = "GAMMA",
                               doing_business_as_name = "", revocation_date = "15-Jul-2026"))
  r <- apply_raw(con, raw2, md_parse_revocations, "revocations", "v2026-08")
  expect_equal(c(r$n_new, r$n_kept, r$n_retracted), c(1, 4, 0))
})

test_that("the second address line is kept as the unit, not joined to the street", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # measured in the 2022 Schedule I sample: line 2 holds suites, PO boxes, buildings
  raw <- data.frame(
    EIN2 = "EIN-11-1111111", OBJECTID = "701", TABLE_ID = c("TID-1", "TID-2"), TAX_YEAR = "2022",
    RETURN_TIME_STAMP = "2023-05-01", SI_02_GRANT_US_ORG_EIN = c("133039601", "530196605"),
    SI_02_GRANT_US_ORG_NAME_L1 = c("ALPHA TRUST", "BETA FUND"), SI_02_GRANT_US_ORG_NAME_L2 = "",
    SI_02_GRANT_US_ORG_ADDR_L1 = c("93 COTTAGE STREET", "103 MAINE AVENUE"),
    SI_02_GRANT_US_ORG_ADDR_L2 = c("SUITE 1", "PO BOX 1358"),
    SI_02_GRANT_US_ORG_ADDR_CITY = "BATH", SI_02_GRANT_US_ORG_ADDR_STATE = "ME",
    SI_02_GRANT_US_ORG_ADDR_ZIP = "04530", stringsAsFactors = FALSE)
  apply_raw(con, raw, md_parse_schedi, "schedi", "v3_1", part = 2022)
  a <- DBI::dbGetQuery(con, "SELECT street_raw, unit_raw FROM address_text ORDER BY street_raw")
  expect_equal(a$street_raw, c("103 MAINE AVENUE", "93 COTTAGE STREET"))
  expect_equal(a$unit_raw, c("PO BOX 1358", "SUITE 1"))

  # npnormalize reads `unit`, so the suite lands in
  # street_unit_id and the PO box stays out of both the street and the unit
  suppressMessages(md_build_text_derived(con, what = "address"))
  d <- DBI::dbGetQuery(con, "SELECT t.street_raw, d.street_key, d.street_unit_id
    FROM address_text t JOIN address_text_derived d USING (address_text_id) ORDER BY t.street_raw")
  expect_equal(d$street_key, c("103 MAINE AVE", "93 COTTAGE ST"))
  expect_equal(d$street_unit_id, c(NA, "1"))
})

test_that("an affiliate listing year without a second address line still parses", {
  skip_if_no_parse_deps()
  con <- parse_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # the published 2009 table has four address columns: no F9_00_AFFIL_ADDR_L2
  raw <- data.frame(
    EIN2 = "EIN-22-2222222", ORG_EIN = "222222222", OBJECTID = "801", TABLE_ID = "TID-0",
    TAX_YEAR = "2009", RETURN_TIME_STAMP = "2010-05-01", F9_00_AFFIL_EIN = "133039601",
    F9_00_AFFIL_NAME_L1 = "ALPHA LODGE 12", F9_00_AFFIL_ADDR_L1 = "1 MAIN ST",
    F9_00_AFFIL_ADDR_CITY = "CHICAGO", F9_00_AFFIL_ADDR_STATE = "IL", F9_00_AFFIL_ADDR_ZIP = "60601",
    stringsAsFactors = FALSE)
  r <- apply_raw(con, raw, md_parse_affiliate_listing, "efile_affiliate_listing", "v3_1", part = 2009)
  expect_equal(r$n_new, 1)
  expect_equal(DBI::dbGetQuery(con, "SELECT street_raw FROM address_text")$street_raw, "1 MAIN ST")
})
