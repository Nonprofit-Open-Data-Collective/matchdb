# md_build_ledger(): pinned files on disk -> one release per file in the ledger.

test_that("the ledger driver applies one release per file and skips them on a rerun", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("digest")
  skip_if_not_installed("stringi")
  root <- tempfile("mdroot"); dir.create(root)
  old <- Sys.getenv("MATCHDB_DATA", unset = NA)
  Sys.setenv(MATCHDB_DATA = root)
  on.exit({
    if (is.na(old)) Sys.unsetenv("MATCHDB_DATA") else Sys.setenv(MATCHDB_DATA = old)
    unlink(root, recursive = TRUE)
  })

  hdr_dir <- md_path("sources", "efile_header", "v3_1", create = TRUE)
  for (yr in c("2021", "2022")) {
    utils::write.csv(data.frame(
      EIN2 = "EIN-13-3039601", OBJECTID = paste0("o", yr), TAX_YEAR = yr,
      RETURN_TIME_STAMP = paste0(yr, "-05-01"), F9_00_ORG_NAME_L1 = "ALPHA TRUST",
      F9_00_ORG_NAME_L2 = "", ORG_NAME_L1 = "", ORG_NAME_L2 = "",
      F9_00_ORG_NAME_DBA_L1 = "", F9_00_ORG_NAME_DBA_L2 = "", F9_00_ORG_ADDR_IN_CARE_OF = "",
      F9_00_ORG_ADDR_L1 = "1 MAIN ST", F9_00_ORG_ADDR_CITY = "CHICAGO",
      F9_00_ORG_ADDR_STATE = "IL", F9_00_ORG_ADDR_ZIP = "60601"),
      file.path(hdr_dir, sprintf("F9-P00-T00-HEADER-%s.CSV", yr)), row.names = FALSE)
  }
  pc_dir <- md_path("sources", "e_postcard", "v2026-07", create = TRUE)
  utils::write.csv(data.frame(
    ein = "530196605", tax_year = "2024", legal_name = "BETA FUND", dba_name_1 = "",
    dba_name_2 = "", dba_name_3 = "", organization_address_line_1 = "2 OAK AVE",
    organization_city = "BOSTON", organization_state = "MA", organization_zip = "02108"),
    file.path(pc_dir, "2026-07-E-POSTCARD.csv"), row.names = FALSE)

  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  V <- list(efile = "v3_1", e_postcard = "v2026-07")
  r1 <- suppressMessages(md_build_ledger(con, V))
  expect_equal(r1$status, rep("applied", 3))
  expect_setequal(r1$part[r1$source == "efile_header"], c("2021", "2022"))
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM release")$n, 3)

  # nothing changed on disk: every file is skipped by its md5
  r2 <- suppressMessages(md_build_ledger(con, V))
  expect_equal(r2$status, rep("unchanged", 3))

  # a source with no version, or no files, is skipped with a message
  expect_message(md_build_ledger(con, list(efile = "v3_1", revocations = "v-none"),
                                 sources = c("revocations", "schedi")),
                 "no files matching")
})
