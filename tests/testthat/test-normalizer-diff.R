# Phase 5 step 7: md_normalizer_diff() (dev/IDENTITY.md section 7).

skip_if_no_diff_deps <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("digest")
  skip_if_not_installed("stringi")
}

# Two signatures side by side, as the database holds them after an npmatch
# upgrade. Names: ALPHA FUND and ALPHA FOUNDATION are two keys under the old
# normalizer and one under the new (a merge); BETA ARTS CTR is one key under
# the old and two spellings come apart under the new (a split); STRASSE is
# rekeyed without regrouping. Addresses replay the npmatch@ddfd967 defect:
# the old normalizer wrote the text "NA" as street_name where there is no street.
diff_db <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  names <- c("ALPHA FUND", "ALPHA FOUNDATION", "BETA ARTS CTR", "BETA ARTS CENTER", "STRASSE FUND")
  ids <- md_name_text_id(names)
  DBI::dbWriteTable(con, "name_text", data.frame(name_text_id = ids, name_raw = names))
  DBI::dbWriteTable(con, "name_text_derived", rbind(
    data.frame(name_text_id = ids, normalize_signature = "v-old",
               name_key = c("ALPHA FUND", "ALPHA FOUNDATION", "BETA ARTS", "BETA ARTS", "STRA E"),
               name_gen = "x"),
    data.frame(name_text_id = ids, normalize_signature = "v-new",
               name_key = c("ALPHA", "ALPHA", "BETA ARTS CTR", "BETA ARTS CENTER", "STRASSE"),
               name_gen = "x")))
  DBI::dbWriteTable(con, "name", data.frame(
    name_id = 1:5, ein = c("EIN-00-0000001", "EIN-00-0000001", "EIN-00-0000002",
                           "EIN-00-0000002", "EIN-00-0000003"),
    name_raw = names, name_text_id = ids))

  streets <- c("1 MAIN ST", NA, NA)
  aids <- md_address_text_id(streets, NA, c("CHICAGO", "BOSTON", "DENVER"), "IL", c("60601", "02108", "80202"), NA)
  DBI::dbWriteTable(con, "address_text", data.frame(address_text_id = aids, street_raw = streets))
  DBI::dbWriteTable(con, "address_text_derived", rbind(
    data.frame(address_text_id = aids, normalize_signature = "v-old",
               street_key = c("1 MAIN ST", "", ""), street_name = c("MAIN", "NA", "NA")),
    data.frame(address_text_id = aids, normalize_signature = "v-new",
               street_key = c("1 MAIN ST", "", ""), street_name = c("MAIN", "", ""))))
  DBI::dbWriteTable(con, "address", data.frame(
    address_id = 1:3, ein = c("EIN-00-0000001", "EIN-00-0000004", "EIN-00-0000005"),
    street_raw = streets, zip5 = c("60601", "02108", "80202"), address_text_id = aids))
  con
}

test_that("the diff counts changed strings per derived column", {
  skip_if_no_diff_deps()
  con <- diff_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  d <- md_normalizer_diff(con, "v-old", "v-new")
  expect_s3_class(d, "md_normalizer_diff")
  expect_equal(d$coverage$n_both, c(5, 3))
  cl <- d$columns
  expect_equal(cl$n_changed[cl$column == "name_key"], 5)
  expect_equal(cl$n_changed[cl$column == "name_gen"], 0)
  expect_equal(cl$n_changed[cl$column == "street_key"], 0)
})

test_that("the ddfd967 defect shows up as exactly the street_name cells it touched", {
  skip_if_no_diff_deps()
  con <- diff_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  d <- md_normalizer_diff(con, "v-old", "v-new")
  cl <- d$columns[d$columns$table == "address_text_derived", ]
  expect_equal(cl$n_changed[cl$column == "street_name"], 2)   # the two streetless addresses
  ex <- d$examples[d$examples$column == "street_name", ]
  expect_equal(ex$old, c("NA", "NA"))
  expect_equal(ex$new, c("", ""))
  # street_key did not move, so no address changes group
  g <- d$groups[d$groups$table == "address", ]
  expect_equal(c(g$n_rows_rekeyed, g$n_merged_groups, g$n_split_groups), c(0, 0, 0))
})

test_that("the diff reports merges, splits and the EINs they touch", {
  skip_if_no_diff_deps()
  con <- diff_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  g <- md_normalizer_diff(con, "v-old", "v-new")$groups
  g <- g[g$table == "name", ]
  expect_equal(g$n_rows, 5)
  expect_equal(g$n_rows_rekeyed, 5)
  expect_equal(g$n_merged_groups, 1)    # ALPHA FUND + ALPHA FOUNDATION
  expect_equal(g$n_split_groups, 1)     # BETA ARTS
  expect_equal(g$n_eins_regrouped, 2)   # STRASSE is rekeyed but regroups nothing
})

test_that("the diff works on tables built before text ids existed", {
  skip_if_no_diff_deps()
  con <- diff_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # today's ingest-built name table has no name_text_id column
  DBI::dbExecute(con, "ALTER TABLE name DROP COLUMN name_text_id")
  g <- md_normalizer_diff(con, "v-old", "v-new")$groups
  expect_equal(g$n_merged_groups[g$table == "name"], 1)
})

test_that("the diff refuses one signature against itself, and prints", {
  skip_if_no_diff_deps()
  con <- diff_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_error(md_normalizer_diff(con, "v-old", "v-old"), "same signature")
  expect_output(print(md_normalizer_diff(con, "v-old", "v-new")), "v-old -> v-new")
})
