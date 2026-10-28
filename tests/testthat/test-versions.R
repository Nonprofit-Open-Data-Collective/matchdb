# Which normalizer built something: npnormalize's version beside npmatch's, in
# pins, source_vintage and stamps; npmatch is only suggested.

test_that("the versions come from npnormalize, and a missing package is NA", {
  v <- .md_normalizer_versions()
  expect_equal(v$npnormalize_version, as.character(utils::packageVersion("npnormalize")))
  expect_equal(v$normalize_signature, npnormalize::np_normalize_signature())
  expect_true(is.na(.md_pkg_version("no.such.package")))
  expect_true(is.na(.md_pkg_commit("no.such.package")))
})

test_that("a pin and its source_vintage row record npnormalize's version", {
  withr::local_envvar(MATCHDB_DATA = tempfile("mdroot"))
  dir <- md_path("sources", "ntee_crosswalk", "v1", create = TRUE)
  f <- file.path(dir, "ntee.csv"); writeLines("a,b", f)
  md_source_pin("ntee_crosswalk", f, version = "v1")
  pin <- md_source_read_pin("ntee_crosswalk", "v1")
  expect_equal(pin$npnormalize_version, as.character(utils::packageVersion("npnormalize")))

  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  md_record_vintage(con, "ntee_crosswalk", "v1", "ntee", 1L)
  sv <- DBI::dbGetQuery(con, "SELECT npnormalize_version FROM source_vintage")
  expect_equal(sv$npnormalize_version, pin$npnormalize_version)
})

test_that("a source_vintage table from before npnormalize gains the column", {
  withr::local_envvar(MATCHDB_DATA = tempfile("mdroot"))
  dir <- md_path("sources", "ntee_crosswalk", "v1", create = TRUE)
  f <- file.path(dir, "ntee.csv"); writeLines("a,b", f)
  md_source_pin("ntee_crosswalk", f, version = "v1")

  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # the table as a 0.1.1 database has it: no npnormalize_version
  old <- md_record_vintage(con, "ntee_crosswalk", "v1", "old_table", 1L)
  DBI::dbExecute(con, "ALTER TABLE source_vintage DROP COLUMN npnormalize_version")
  expect_false("npnormalize_version" %in% DBI::dbListFields(con, "source_vintage"))

  md_record_vintage(con, "ntee_crosswalk", "v1", "ntee", 1L)
  sv <- DBI::dbGetQuery(con, "SELECT table_name, npnormalize_version FROM source_vintage ORDER BY 1")
  expect_equal(sv$table_name, c("ntee", "old_table"))
  expect_equal(sv$npnormalize_version[1], as.character(utils::packageVersion("npnormalize")))
  expect_true(is.na(sv$npnormalize_version[2]))
})
