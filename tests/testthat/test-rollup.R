# Phase 5 step 6: name and address rebuilt from the ledger (?md_rollup).

skip_if_no_rollup_deps <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("digest")
  skip_if_not_installed("stringi")
}

rollup_con <- function(eins) {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbWriteTable(con, "entity", data.frame(ein = eins, layer = "bmf_active"))
  con
}

put <- function(con, df, source, version, ...) {
  DBI::dbWriteTable(con, "frame_t", df, overwrite = TRUE)
  suppressMessages(md_apply_release(con, "frame_t", source, version, ...))
}

hdr_row <- function(objectid, name, year, street, ein = "EIN-00-0000001", filed = NA) data.frame(
  ein = ein, role = "legal", name_raw = name, street_raw = street, city_raw = "CHICAGO",
  state = "IL", zip5 = "60601", record_key = objectid, period = year, filed_at = filed,
  stringsAsFactors = FALSE)

test_that("a superseded 990 legal name is former, and the newest address is mailing", {
  skip_if_no_rollup_deps()
  con <- rollup_con("EIN-00-0000001"); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  put(con, hdr_row("o20", "ALPHA OLD NAME", 2020, "1 OLD RD"), "efile_header", "v3_1", part = 2020)
  put(con, hdr_row("o21", "ALPHA NEW NAME", 2021, "9 NEW ST"), "efile_header", "v3_1", part = 2021)
  put(con, hdr_row("o22", "ALPHA NEW NAME", 2022, "9 NEW ST"), "efile_header", "v3_1", part = 2022)
  suppressMessages(md_build_rollups(con))
  n <- DBI::dbGetQuery(con, "SELECT name_raw, variant_class, n_obs, first_year, last_year
                             FROM rollup_name ORDER BY name_raw")
  expect_equal(n$variant_class, c("legal", "former"))
  expect_equal(n$n_obs, c(2, 1))            # n_support for a series: distinct years
  a <- DBI::dbGetQuery(con, "SELECT street_raw, variant_class, spell_rank
                             FROM rollup_address ORDER BY spell_rank")
  expect_equal(a$street_raw, c("9 NEW ST", "1 OLD RD"))
  expect_equal(a$variant_class, c("mailing", "historical"))
})

test_that("only a filer's latest return for a year counts toward mentions", {
  skip_if_no_rollup_deps()
  con <- rollup_con("EIN-00-0000001"); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  g <- function(objectid, filed, filer = "EIN-11-1111111") data.frame(
    ein = "EIN-00-0000001", role = "observed", name_raw = "Alpha Trust Fdn",
    street_raw = "1 MAIN ST", city_raw = "CHICAGO", state = "IL", zip5 = "60601",
    asserted_by = filer, record_key = objectid, period = 2022, filed_at = filed,
    stringsAsFactors = FALSE)
  # filer 1 files a return and then an amended one listing the same grant;
  # filer 2 lists it twice on one return
  put(con, rbind(g("o1", "2023-01-10"), g("o2", "2023-06-30"),
                 g("o3", "2023-02-01", "EIN-22-2222222"), g("o3", "2023-02-01", "EIN-22-2222222")),
      "schedi", "v3_1", part = 2022)
  suppressMessages(md_build_rollups(con))
  n <- DBI::dbGetQuery(con, "SELECT n_obs, n_mentions, n_corroborators FROM rollup_name")
  expect_equal(c(n$n_mentions, n$n_corroborators), c(3, 2))   # 1 (latest return) + 2
  expect_equal(n$n_obs, 3)
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM obs")$n, 4)   # the ledger keeps all four
})

test_that("rollup ids are stable across rebuilds; integer ids are not promised", {
  skip_if_no_rollup_deps()
  con <- rollup_con(c("EIN-00-0000001", "EIN-00-0000002")); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  put(con, hdr_row("o1", "ZETA TRUST", 2021, "1 MAIN ST"), "efile_header", "v3_1", part = 2021)
  suppressMessages(md_build_rollups(con))
  before <- DBI::dbGetQuery(con, "SELECT name_uid, name_raw FROM rollup_name")
  # a re-release of the partition with a late filing added; AARDVARK sorts first,
  # so every integer id after it moves
  put(con, rbind(hdr_row("o1", "ZETA TRUST", 2021, "1 MAIN ST"),
                 hdr_row("o2", "AARDVARK FUND", 2021, "2 OAK AVE", ein = "EIN-00-0000002")),
      "efile_header", "v3_2", part = 2021)
  suppressMessages(md_build_rollups(con))
  after <- DBI::dbGetQuery(con, "SELECT name_uid, name_raw FROM rollup_name")
  expect_true(before$name_uid %in% after$name_uid)
  expect_equal(after$name_raw[after$name_uid == before$name_uid], "ZETA TRUST")
})

test_that("EINs missing from entity are held back", {
  skip_if_no_rollup_deps()
  con <- rollup_con("EIN-00-0000001"); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  put(con, rbind(hdr_row("o1", "ALPHA", 2021, "1 MAIN ST"),
                 hdr_row("o2", "UNKNOWN ORG", 2021, "2 OAK AVE", ein = "EIN-99-9999999")),
      "efile_header", "v3_1", part = 2021)
  expect_message(md_build_rollups(con), "1 EIN\\(s\\) in the ledger but not in entity")
  expect_equal(DBI::dbGetQuery(con, "SELECT DISTINCT ein FROM rollup_name")$ein, "EIN-00-0000001")
})

test_that("installing the rollups links derived columns and keeps the old tables", {
  skip_if_no_rollup_deps()
  skip_if_not_installed("npmatch")
  con <- rollup_con("EIN-00-0000001"); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "name", data.frame(name_id = 1L, ein = "EIN-00-0000001", name_raw = "OLD"))
  DBI::dbWriteTable(con, "address", data.frame(address_id = 1L, ein = "EIN-00-0000001"))
  put(con, rbind(hdr_row("o1", "ALPHA TRUST", 2021, "123 Main St"),
                 hdr_row("o2", "ALPHA TRUST", 2022, "123 MAIN STREET")),
      "efile_header", "v3_1", part = 2021)
  suppressMessages(md_build_rollups(con))
  # without derived columns the install is refused, and nothing is touched
  expect_error(md_install_rollups(con), "md_build_text_derived")
  expect_false(DBI::dbExistsTable(con, "name_legacy"))
  expect_equal(DBI::dbGetQuery(con, "SELECT name_raw FROM name")$name_raw, "OLD")
  suppressMessages(md_build_text_derived(con))
  md_install_rollups(con)
  expect_equal(DBI::dbGetQuery(con, "SELECT name_raw FROM name_legacy")$name_raw, "OLD")
  expect_silent(md_check_derived_fresh(con))
  nd <- DBI::dbGetQuery(con, "SELECT n.name_raw, d.name_key FROM name n JOIN name_derived d USING (name_id)")
  expect_equal(nrow(nd), 1)

  # the two spellings of 123 Main St are two address rows but one place
  expect_equal(.md_n(con, "address"), 2)
  suppressMessages(md_build_compact(con, what = "address"))
  ac <- DBI::dbGetQuery(con, "SELECT street_key, n_contributing_rows FROM address_compact")
  expect_equal(nrow(ac), 1)
  expect_equal(ac$street_key, "123 MAIN ST")
  expect_equal(ac$n_contributing_rows, 2)
})
