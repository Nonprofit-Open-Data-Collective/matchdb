# Phase 5 step 3: text dictionaries and derived columns keyed on the text
# (dev/IDENTITY.md sections 4 and 7).

skip_if_no_text_deps <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("digest")
  skip_if_not_installed("stringi")
  skip_if_not_installed("npnormalize")
}

# A small name and address table shaped like the real ones. Ids are a running
# counter, as the ingests assign them today.
text_db <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbWriteTable(con, "name", data.frame(
    name_id = 1:6,
    ein = c("EIN-00-0000001", "EIN-00-0000002", "EIN-00-0000003", "EIN-00-0000004",
            "EIN-00-0000005", "EIN-00-0000006"),
    name_raw = c("ALPHA TRUST", " ALPHA  TRUST ", "Beta Fund Inc", "TOASTMASTERS INTERNATIONAL",
                 "TOASTMASTERS INTERNATIONAL", ""),
    source = "bmf", stringsAsFactors = FALSE))
  DBI::dbWriteTable(con, "address", data.frame(
    address_id = 1:4,
    ein = c("EIN-00-0000001", "EIN-00-0000002", "EIN-00-0000003", "EIN-00-0000004"),
    street_raw = c("1 MAIN ST", "1 MAIN ST", "200 Oak Avenue Suite 5", NA),
    city_raw = c("CHICAGO", "CHICAGO", "Boston", NA),
    state = c("IL", "IL", "MA", NA),
    zip5 = c("60601", "60601", "02108", NA),
    zip_plus4 = c("1234", "1234", NA, NA),
    source = "bmf", stringsAsFactors = FALSE))
  con
}

test_that("the dictionary holds each distinct string once", {
  skip_if_no_text_deps()
  con <- text_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  n <- md_build_text(con)
  # ALPHA TRUST twice (whitespace only), Beta, TOASTMASTERS twice; the empty name is skipped
  expect_equal(.md_n(con, "name_text"), 3)
  # the two CHICAGO rows are one address; the all-NA row says nothing
  expect_equal(.md_n(con, "address_text"), 2)
  ids <- DBI::dbGetQuery(con, "SELECT name_text_id FROM name_text ORDER BY name_raw")$name_text_id
  expect_equal(ids, md_name_text_id(c("ALPHA TRUST", "Beta Fund Inc", "TOASTMASTERS INTERNATIONAL")))
  # adding the same text again adds nothing
  expect_equal(unname(md_build_text(con)), c(0, 0))
})

test_that("only strings without a row for the signature are normalized", {
  skip_if_no_text_deps()
  con <- text_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  md_build_text(con)
  first <- md_build_text_derived(con)
  expect_equal(unname(first), c(3, 2))
  expect_equal(unname(md_build_text_derived(con)), c(0, 0))
  chk <- md_check_text_derived(con)
  expect_equal(chk$n_missing, c(0, 0))
})

test_that("a re-ingest with new row ids normalizes nothing and orphans nothing", {
  skip_if_no_text_deps()
  con <- text_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  md_build_text(con); md_build_text_derived(con)
  # the way every ingest re-runs today: delete, re-insert, new ids
  DBI::dbExecute(con, "UPDATE name SET name_id = name_id + 1000")
  DBI::dbExecute(con, "UPDATE address SET address_id = address_id + 1000")
  expect_equal(unname(md_build_text(con)), c(0, 0))
  expect_equal(unname(md_build_text_derived(con)), c(0, 0))
  expect_equal(md_check_text_derived(con)$n_missing, c(0, 0))
})

test_that("text-keyed columns equal what md_build_derived() stores per row", {
  skip_if_no_text_deps()
  con <- text_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # md_build_derived() expects every name to be a real row; drop the blank one
  DBI::dbExecute(con, "DELETE FROM name WHERE name_raw = ''")
  DBI::dbExecute(con, "DELETE FROM address WHERE street_raw IS NULL")
  suppressMessages(md_build_derived(con))
  md_build_text(con); suppressMessages(md_build_text_derived(con))
  md_identity_macros(con)
  sig <- npnormalize::np_normalize_signature()
  cols <- paste(sprintf("d.%s", .md_derived_name_cols), collapse = ", ")
  by_row <- DBI::dbGetQuery(con, sprintf(
    "SELECT n.name_id, %s FROM name n JOIN name_derived d USING (name_id) ORDER BY n.name_id", cols))
  by_text <- DBI::dbGetQuery(con, sprintf(
    "SELECT n.name_id, %s FROM name n
     JOIN name_text_derived d ON d.name_text_id = md_name_text_id(n.name_raw)
                             AND d.normalize_signature = '%s'
     ORDER BY n.name_id", cols, sig))
  expect_equal(by_text, by_row, ignore_attr = TRUE)

  acols <- paste(sprintf("d.%s", .md_address_cols()), collapse = ", ")
  a_row <- DBI::dbGetQuery(con, sprintf(
    "SELECT a.address_id, %s FROM address a JOIN address_derived d USING (address_id)
     ORDER BY a.address_id", acols))
  a_text <- DBI::dbGetQuery(con, sprintf(
    "SELECT a.address_id, %s FROM address a
     JOIN address_text_derived d
       ON d.address_text_id = md_address_text_id(a.street_raw, NULL, a.city_raw, a.state,
                                                 a.zip5, a.zip_plus4)
      AND d.normalize_signature = '%s'
     ORDER BY a.address_id", acols, sig))
  expect_equal(a_text, a_row, ignore_attr = TRUE)
})

test_that("two normalizer signatures sit side by side", {
  skip_if_no_text_deps()
  con <- text_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  md_build_text(con); suppressMessages(md_build_text_derived(con))
  # an older normalizer's rows for one string, as a published tier would have them
  DBI::dbExecute(con, "
    INSERT INTO name_text_derived (name_text_id, normalize_signature, name_key)
    SELECT name_text_id, 'v0-older', 'OLD ' || name_raw FROM name_text LIMIT 1")
  st <- md_text_stats(con)
  sigs <- st$signatures[st$signatures$table == "name_text_derived", ]
  expect_setequal(sigs$normalize_signature, c(npnormalize::np_normalize_signature(), "v0-older"))
  # the current signature is still complete, the older one is not
  expect_equal(md_check_text_derived(con)$n_missing, c(0, 0))
  old <- md_check_text_derived(con, signature = "v0-older")
  expect_equal(old$n_missing[old$table == "name_text_derived"], 2)
  expect_error(md_check_text_derived(con, signature = "v0-older", stop_on_missing = TRUE),
               "md_build_text_derived")
  # a rebuild under the current signature leaves the older rows alone
  expect_equal(unname(md_build_text_derived(con)), c(0, 0))
  expect_equal(DBI::dbGetQuery(con,
    "SELECT count(*) n FROM name_text_derived WHERE normalize_signature = 'v0-older'")$n, 1)
})

test_that("md_text_stats reports rows against distinct strings", {
  skip_if_no_text_deps()
  con <- text_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  md_build_text(con)
  s <- md_text_stats(con)$sizes
  expect_equal(s$rows, c(6, 4))
  expect_equal(s$distinct_text, c(3, 2))
})
