# Phase 5 step 4: the observation ledger and md_apply_release()
# (dev/IDENTITY.md sections 4, 5 and 8).

skip_if_no_ledger_deps <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("digest")
  skip_if_not_installed("stringi")
}

ledger_con <- function() DBI::dbConnect(duckdb::duckdb())

# Write a data frame as the frame table and apply it.
apply_df <- function(con, df, source, version, ...) {
  DBI::dbWriteTable(con, "frame_t", df, overwrite = TRUE)
  suppressMessages(md_apply_release(con, "frame_t", source, version, ...))
}

live <- function(con, where = "TRUE") DBI::dbGetQuery(con, sprintf(
  "SELECT * FROM obs WHERE retracted_in IS NULL AND %s ORDER BY obs_id", where))

# The whole ledger, minus the one column that records wall-clock time.
ledger_state <- function(con) list(
  obs = DBI::dbGetQuery(con, "SELECT * FROM obs ORDER BY obs_id"),
  release = DBI::dbGetQuery(con, "SELECT * EXCLUDE (ingested_at) FROM release ORDER BY release_id"),
  name_text = DBI::dbGetQuery(con, "SELECT * FROM name_text ORDER BY name_text_id"),
  address_text = DBI::dbGetQuery(con, "SELECT * FROM address_text ORDER BY address_text_id"))

hdr <- function(objectid, ein, name, year, street = "1 MAIN ST") data.frame(
  ein = ein, role = "legal", name_raw = name, street_raw = street, city_raw = "CHICAGO",
  state = "IL", zip5 = "60601", record_key = objectid, period = year,
  stringsAsFactors = FALSE)

## ---- series and the partition diff ---------------------------------------------

test_that("a series release is inserted, and applying it again changes nothing", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  f <- rbind(hdr("o1", "EIN-00-0000001", "ALPHA TRUST", 2021),
             hdr("o2", "EIN-00-0000002", "BETA FUND", 2021))
  r1 <- apply_df(con, f, "efile_header", "v3_1", part = 2021)
  expect_equal(c(r1$n_rows, r1$n_new, r1$n_kept, r1$n_retracted), c(2, 2, 0, 0))
  before <- ledger_state(con)
  r2 <- apply_df(con, f, "efile_header", "v3_1", part = 2021)
  expect_equal(c(r2$n_new, r2$n_kept, r2$n_retracted), c(0, 2, 0))
  expect_identical(ledger_state(con), before)
})

test_that("the observation id can be recomputed in R from the raw row", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  apply_df(con, hdr("o1", "EIN-00-0000001", "ALPHA TRUST", 2021), "efile_header", "v3_1", part = 2021)
  o <- live(con)
  nid <- md_name_text_id("ALPHA TRUST")
  aid <- md_address_text_id("1 MAIN ST", NA, "CHICAGO", "IL", "60601", NA)
  row <- md_hash_id("row.v1", "EIN-00-0000001", "legal", nid, aid, NA, 2021)
  expect_equal(o$obs_id, md_hash_id("obs.v1", "efile_header", "o1", row, 1))
  expect_equal(c(o$name_text_id, o$address_text_id), c(nid, aid))
})

test_that("a re-released partition adds late rows, retracts withdrawn ones, and restores returns", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  a <- hdr("o1", "EIN-00-0000001", "ALPHA TRUST", 2021)
  b <- hdr("o2", "EIN-00-0000002", "BETA FUND", 2021)
  late <- hdr("o3", "EIN-00-0000003", "GAMMA SOCIETY", 2021)
  apply_df(con, rbind(a, b), "efile_header", "v3_1", part = 2021)
  r <- apply_df(con, rbind(a, late), "efile_header", "v3_2", part = 2021)
  expect_equal(c(r$n_new, r$n_kept, r$n_retracted), c(1, 1, 1))
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM obs")), 3)   # nothing deleted
  expect_setequal(live(con)$record_key, c("o1", "o3"))
  # BETA comes back in a later release: un-retracted, same id
  r <- apply_df(con, rbind(a, b, late), "efile_header", "v3_3", part = 2021)
  expect_equal(c(r$n_new, r$n_retracted), c(0, 0))
  expect_setequal(live(con)$record_key, c("o1", "o2", "o3"))
})

test_that("a corrected value in a re-released filing is a new row, not a silent update", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  apply_df(con, hdr("o1", "EIN-00-0000001", "ALPHA TRSUT", 2021), "efile_header", "v3_1", part = 2021)
  r <- apply_df(con, hdr("o1", "EIN-00-0000001", "ALPHA TRUST", 2021), "efile_header", "v3_2", part = 2021)
  expect_equal(c(r$n_new, r$n_retracted), c(1, 1))
  expect_equal(live(con)$name_text_id, md_name_text_id("ALPHA TRUST"))
})

test_that("partitions are diffed independently", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  apply_df(con, hdr("o1", "EIN-00-0000001", "ALPHA TRUST", 2021), "efile_header", "v3_1", part = 2021)
  r <- apply_df(con, hdr("o9", "EIN-00-0000001", "ALPHA TRUST", 2022), "efile_header", "v3_1", part = 2022)
  expect_equal(c(r$n_new, r$n_retracted), c(1, 0))   # 2022 does not retract 2021
  expect_equal(nrow(live(con)), 2)
})

test_that("a file already applied is skipped by its md5", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  f <- hdr("o1", "EIN-00-0000001", "ALPHA TRUST", 2021)
  apply_df(con, f, "efile_header", "v3_1", part = 2021, file_md5 = "abc")
  expect_equal(apply_df(con, f, "efile_header", "v3_1", part = 2021, file_md5 = "abc")$status,
               "unchanged")
})

## ---- mentions: every row counts ---------------------------------------------------

grant <- function(objectid, n, filer = "EIN-11-1111111", period = 2022) data.frame(
  ein = rep("EIN-00-0000001", n), role = "observed", name_raw = "Alpha Trust Fdn",
  street_raw = "1 MAIN ST", city_raw = "CHICAGO", state = "IL", zip5 = "60601",
  asserted_by = filer, record_key = objectid, trace_key = sprintf("TID-%03d", seq_len(n)),
  period = period, stringsAsFactors = FALSE)

test_that("a pooled mentions file writing a pair 3, then 5, then 2 times counts 3, 5, 2", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # a pooled file: no filing id, so the record key is empty and the row hash alone identifies
  pooled <- function(n) { g <- grant("", n); g$record_key <- ""; g }
  counts <- vapply(c(3, 5, 2), function(n) {
    apply_df(con, pooled(n), "irs527_related", sprintf("v-%d", n))
    nrow(live(con))
  }, numeric(1))
  expect_equal(counts, c(3, 5, 2))
  # count-preserving: occurrences 1-2 survived throughout, 3 came and went
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM obs")), 5)
})

test_that("identical grant lines in one return are two observations", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- apply_df(con, rbind(grant("o1", 2), grant("o2", 1, filer = "EIN-22-2222222")),
                "schedi", "v3_1", part = 2022)
  expect_equal(r$n_new, 3)
  o <- live(con)
  expect_equal(sum(o$record_key == "o1"), 2)
  expect_equal(length(unique(o$name_text_id)), 1)        # one string, three mentions
  expect_equal(length(unique(o$asserted_by)), 2)         # by two writers
})

## ---- snapshot spells ----------------------------------------------------------------

snap <- function(name) if (is.na(name)) {
  data.frame(ein = character(0), role = character(0), name_raw = character(0),
             record_key = character(0))
} else data.frame(ein = "EIN-00-0000001", role = "legal", name_raw = name,
                  record_key = "EIN-00-0000001", stringsAsFactors = FALSE)

test_that("a snapshot run of A, A, B, A, then gone gives three spells", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  vals <- c("2026-01" = "ALPHA", "2026-02" = "ALPHA", "2026-03" = "BRAVO",
            "2026-04" = "ALPHA", "2026-05" = NA)
  for (v in names(vals)) apply_df(con, snap(vals[[v]]), "bmf_active", v, vintage = v)
  s <- DBI::dbGetQuery(con, "
    SELECT n.name_raw, o.first_seen, o.last_seen, o.bounds_kind
    FROM obs o JOIN name_text n USING (name_text_id) ORDER BY o.first_seen")
  expect_equal(nrow(s), 3)
  expect_equal(s$name_raw, c("ALPHA", "BRAVO", "ALPHA"))
  expect_equal(s$first_seen, c("2026-01", "2026-03", "2026-04"))
  expect_equal(s$last_seen, c("2026-02", "2026-03", "2026-04"))   # gone in 2026-05: not extended
  expect_true(all(s$bounds_kind == "spell"))
})

test_that("snapshot releases must arrive in order, and a repeat is a no-op", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  apply_df(con, snap("ALPHA"), "bmf_active", "2026-02", vintage = "2026-02")
  before <- ledger_state(con)
  expect_equal(apply_df(con, snap("ALPHA"), "bmf_active", "2026-02", vintage = "2026-02")$status,
               "already_applied")
  expect_identical(ledger_state(con), before)
  expect_error(apply_df(con, snap("ALPHA"), "bmf_active", "2026-01", vintage = "2026-01"),
               "not newer")
})

## ---- replay equality ------------------------------------------------------------------

test_that("applying releases one at a time, with repeats, equals a clean replay", {
  skip_if_no_ledger_deps()
  a <- hdr("o1", "EIN-00-0000001", "ALPHA TRUST", 2021)
  b <- hdr("o2", "EIN-00-0000002", "BETA FUND", 2021)
  c3 <- hdr("o3", "EIN-00-0000003", "GAMMA SOCIETY", 2021)
  series <- list(list(rbind(a, b), "v1"), list(rbind(a, c3), "v2"), list(rbind(a, b, c3), "v3"))
  snaps <- list(list("ALPHA", "2026-01"), list("BRAVO", "2026-02"), list("ALPHA", "2026-03"))

  messy <- ledger_con(); on.exit(DBI::dbDisconnect(messy, shutdown = TRUE), add = TRUE)
  clean <- ledger_con(); on.exit(DBI::dbDisconnect(clean, shutdown = TRUE), add = TRUE)
  for (i in seq_along(series)) {
    for (con in list(messy, clean)) {
      apply_df(con, series[[i]][[1]], "efile_header", series[[i]][[2]], part = 2021)
      apply_df(con, snap(snaps[[i]][[1]]), "bmf_active", snaps[[i]][[2]], vintage = snaps[[i]][[2]])
    }
    # the messy one re-applies everything it has just seen
    apply_df(messy, series[[i]][[1]], "efile_header", series[[i]][[2]], part = 2021)
    apply_df(messy, snap(snaps[[i]][[1]]), "bmf_active", snaps[[i]][[2]], vintage = snaps[[i]][[2]])
  }
  expect_identical(ledger_state(messy), ledger_state(clean))
})

## ---- parsers ----------------------------------------------------------------------------

test_that("the four parsers produce frames the engine accepts", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbWriteTable(con, "raw_hdr", data.frame(
    EIN2 = c("EIN-13-3039601", "EIN-53-0196605"), OBJECTID = c("201", "202"),
    TAX_YEAR = "2022", RETURN_TIME_STAMP = c("2023-05-01T10:00:00", "2023-06-01T10:00:00"),
    F9_00_ORG_NAME_L1 = c("ALPHA TRUST", "BETA FUND"), F9_00_ORG_NAME_L2 = c("", "INC"),
    ORG_NAME_L1 = NA_character_, ORG_NAME_L2 = NA_character_,
    F9_00_ORG_NAME_DBA_L1 = c("ALPHA", ""), F9_00_ORG_NAME_DBA_L2 = "",
    F9_00_ORG_ADDR_IN_CARE_OF = c("", "% TREASURER"),
    F9_00_ORG_ADDR_L1 = c("1 MAIN ST", "2 OAK AVE"), F9_00_ORG_ADDR_CITY = c("CHICAGO", "BOSTON"),
    F9_00_ORG_ADDR_STATE = c("IL", "MA"), F9_00_ORG_ADDR_ZIP = c("60601-1234", "02108"),
    stringsAsFactors = FALSE))
  r <- suppressMessages(md_apply_release(con, md_parse_efile_header(con, "raw_hdr"),
                                         "efile_header", "v3_1", part = 2022))
  expect_equal(r$n_new, 4)    # 2 legal + 1 dba + 1 in care of
  o <- live(con, "source = 'efile_header'")
  expect_setequal(o$role, c("legal", "legal", "dba", "in_care_of"))
  expect_true(all(!is.na(o$address_text_id)))
  expect_equal(DBI::dbGetQuery(con, "SELECT zip_plus4 FROM address_text WHERE zip5 = '60601'")$zip_plus4, "1234")

  DBI::dbWriteTable(con, "raw_si", data.frame(
    EIN2 = "EIN-11-1111111", OBJECTID = "301", TABLE_ID = c("TID-000", "TID-001", "TID-002", "TID-003"),
    TAX_YEAR = "2022", RETURN_TIME_STAMP = "2023-05-01",
    SI_02_GRANT_US_ORG_EIN = c("133039601", "133039601", "12-34", "999999999999"),
    SI_02_GRANT_US_ORG_NAME_L1 = c("Alpha Trust Fdn", "Alpha Trust Fdn", "Small Org", "Bad EIN"),
    SI_02_GRANT_US_ORG_NAME_L2 = "", SI_02_GRANT_US_ORG_ADDR_L1 = "1 MAIN ST",
    SI_02_GRANT_US_ORG_ADDR_L2 = "", SI_02_GRANT_US_ORG_ADDR_CITY = "CHICAGO",
    SI_02_GRANT_US_ORG_ADDR_STATE = "IL", SI_02_GRANT_US_ORG_ADDR_ZIP = "60601",
    stringsAsFactors = FALSE))
  r <- suppressMessages(md_apply_release(con, md_parse_schedi(con, "raw_si"), "schedi", "v3_1", part = 2022))
  expect_equal(r$n_new, 3)    # the twelve-digit EIN is dropped, not coerced
  o <- live(con, "source = 'schedi'")
  expect_setequal(o$ein, c("EIN-13-3039601", "EIN-00-0001234"))
  expect_true(all(o$asserted_by == "EIN-11-1111111"))

  DBI::dbWriteTable(con, "raw_bmf", data.frame(
    ein = c("13-3039601", "53-0196605"), org_name_raw = c("ALPHA TRUST", "BETA FUND INC"),
    dba_name_raw = c("ALPHA", ""), in_care_of_name_raw = c("", "% TREASURER"),
    org_addr_street_raw = c("1 MAIN ST", ""), org_addr_city_raw = c("CHICAGO", ""),
    org_addr_state_raw = c("IL", ""), org_addr_zip_raw = c("60601-1234", ""),
    stringsAsFactors = FALSE))
  r <- suppressMessages(md_apply_release(con, md_parse_bmf_active(con, "raw_bmf"),
                                         "bmf_active", "v2026-01", vintage = "2026-01"))
  # 2 legal + 1 dba + 1 in care of + 1 address; the empty address says nothing
  expect_equal(r$n_new, 5)
  o <- live(con, "source = 'bmf_active'")
  expect_true(all(is.na(o$address_text_id[o$role != "mailing"])))
  expect_true(all(o$bounds_kind == "spell"))

  DBI::dbWriteTable(con, "raw_xw", data.frame(
    EIN2 = "EIN-13-3039601", spell_rank = c("0", "1"),
    street = c("1 MAIN ST", "9 OLD RD"), city = c("CHICAGO", "EVANSTON"), state = "IL",
    zip5 = c("60601", "60201"), first_vintage = c("2019-01", "2010-01"),
    last_vintage = c("2026-07", "2018-12"), stringsAsFactors = FALSE))
  r <- suppressMessages(md_apply_release(con, md_parse_address_crosswalk(con, "raw_xw"),
                                         "address_crosswalk", "2026-08"))
  expect_equal(r$n_new, 2)
  o <- live(con, "source = 'address_crosswalk'")
  expect_true(all(o$bounds_kind == "stated"))
  expect_setequal(o$first_seen, c("2019-01", "2010-01"))
  # the next crosswalk extends the current spell's range in place
  DBI::dbExecute(con, "UPDATE raw_xw SET last_vintage = '2026-10' WHERE spell_rank = '0'")
  r <- suppressMessages(md_apply_release(con, md_parse_address_crosswalk(con, "raw_xw"),
                                         "address_crosswalk", "2026-11"))
  expect_equal(c(r$n_new, r$n_kept, r$n_retracted), c(0, 2, 0))
  expect_true("2026-10" %in% live(con, "source = 'address_crosswalk'")$last_seen)
})

test_that("a frame without its key columns is refused", {
  skip_if_no_ledger_deps()
  con <- ledger_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_error(apply_df(con, data.frame(ein = "EIN-00-0000001", name_raw = "X"),
                        "efile_header", "v1", part = 2021), "record_key")
})
