# Phase 5 step 1 (dev/IDENTITY.md section 3): the id recipes. Ingest hashes in
# SQL; anyone verifying a row by hand hashes in R. These tests hold the two to
# identical output, and pin a few ids to values computed by a third md5
# implementation, so a change to either side cannot pass silently.

skip_if_no_identity_deps <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("digest")
  skip_if_not_installed("stringi")
}

sql_con <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  md_identity_macros(con)
  con
}

# Run a macro over R vectors in DuckDB and return the result column.
sql_apply <- function(con, expr, ...) {
  d <- data.frame(..., stringsAsFactors = FALSE)
  DBI::dbWriteTable(con, "probe", d, overwrite = TRUE)
  DBI::dbGetQuery(con, sprintf("SELECT %s AS out FROM probe ORDER BY i", expr))$out
}

test_that("md_canon changes whitespace and Unicode form only", {
  skip_if_no_identity_deps()
  expect_equal(md_canon("  Alpha   Trust  "), "Alpha Trust")
  expect_equal(md_canon("Alpha\tTrust\n"), "Alpha Trust")
  expect_equal(md_canon("Alpha Trust"), "Alpha Trust")         # no-break space
  expect_equal(md_canon("Alpha\x1fTrust"), "Alpha Trust")           # the separator
  expect_equal(md_canon("Alpha\x07Trust"), "Alpha Trust")           # other control chars
  expect_equal(md_canon("Café"), "Café")                 # NFC
  expect_equal(md_canon(c(NA, "")), c("", ""))
  # what it must NOT touch: case, punctuation, inner single spaces
  expect_equal(md_canon("St. Mary's  CHURCH, Inc."), "St. Mary's CHURCH, Inc.")
  expect_equal(md_canon(12345), "12345")
})

test_that("ids match values computed by an independent md5", {
  skip_if_no_identity_deps()
  expect_equal(md_name_text_id("ALPHA TRUST"), "39e22c407307a653bc4b90d25970c01e")
  expect_equal(md_name_text_id(" ALPHA\tTRUST "), "39e22c407307a653bc4b90d25970c01e")
  expect_equal(md_name_text_id("Café du  Monde"), "9d8a16fa425f4488c693bffbf26548d0")
  expect_equal(md_address_text_id("1 MAIN ST", NA, "CHICAGO", "IL", "60601", "1234"),
               "7c02f7b8b8856ff340cf1536431e76e5")
  expect_equal(md_release_id("schedi", "v2_3", 2024), "4d952ab292808c9a4f51097cd4339e83")
  expect_equal(md_release_id("bmf_unified", "v2026-08-11"), "e5847f169fc948cec925da9b3022d13c")
})

test_that("field boundaries cannot be forged", {
  skip_if_no_identity_deps()
  expect_false(md_hash_id("t", "AB", "C") == md_hash_id("t", "A", "BC"))
  # a separator inside a field is folded to a space, so it cannot fake two fields
  expect_false(md_hash_id("t", "A\x1fB") == md_hash_id("t", "A", "B"))
  # the tag is part of the id: the same text under two recipes differs
  expect_false(md_hash_id("x.v1", "A") == md_hash_id("y.v1", "A"))
  # case is kept
  expect_false(md_name_text_id("United Way") == md_name_text_id("UNITED WAY"))
})

test_that("a recipe refuses the wrong number of fields", {
  skip_if_no_identity_deps()
  expect_error(md_hash_id("addr.v1", "1 MAIN ST"), "takes 6")
  expect_error(md_hash_id("name.v1", "A", "B"), "takes 1")
  expect_error(do.call(md_hash_id, c(list("t"), as.list(letters[1:9]))), "1 to 8")
})

test_that("R and SQL agree on fixed hard cases", {
  skip_if_no_identity_deps()
  x <- c("ALPHA TRUST", "  lead and trail  ", "tab\there", "new\nline", "cr\r\nlf",
         "nbsp here", "sep\x1fhere", "bell\x07here", "del\x7fhere",
         "Café", "Café", "北京大学", "emoji \U0001F600 ok",
         "", "   ", "St. Mary's CHURCH, Inc.", "Ünïcödé  ÄÖÜ")
  con <- sql_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  i <- seq_along(x)
  expect_identical(sql_apply(con, "md_canon(x)", i = i, x = x), md_canon(x))
  expect_identical(sql_apply(con, "md_name_text_id(x)", i = i, x = x), md_name_text_id(x))
  # NULL in SQL behaves as NA in R
  expect_identical(sql_apply(con, "md_name_text_id(NULL)", i = 1L), md_name_text_id(NA))
})

test_that("R and SQL agree on random strings", {
  skip_if_no_identity_deps()
  set.seed(20261024)
  pool <- c(letters, LETTERS, 0:9, " ", "  ", "\t", "\n", "\r", " ", "\x1f",
            "\x01", "\x7f", ".", ",", "'", "&", "-", "/",
            "é", "é", "ñ", "ñ", "Å", "Å",
            "北", "京", "Ж", "Ω", "\U0001F600", "—")
  x <- vapply(1:3000, function(k) paste(sample(pool, sample(0:25, 1), TRUE),
                                        collapse = ""), character(1))
  con <- sql_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  i <- seq_along(x)
  expect_identical(sql_apply(con, "md_canon(x)", i = i, x = x), md_canon(x))
  expect_identical(sql_apply(con, "md_name_text_id(x)", i = i, x = x), md_name_text_id(x))
})

test_that("R and SQL agree on address and release ids, NULLs included", {
  skip_if_no_identity_deps()
  d <- data.frame(
    i = 1:4,
    street = c("1 MAIN ST", "2 Oak  Ave", NA, "PO BOX 7"),
    unit = c(NA, "STE 100", NA, ""),
    city = c("CHICAGO", "Boston", "NOWHERE", NA),
    state = c("IL", "MA", NA, "XX"),
    zip5 = c("60601", "02108", "00000", NA),
    zip4 = c("1234", NA, NA, NA),
    source = c("schedi", "bmf_unified", "e_postcard", "schedi"),
    version = c("v2_3", "v2026-08-11", "v2026-07", "v2_3"),
    part = c("2024", NA, NA, "2009"),
    stringsAsFactors = FALSE)
  con <- sql_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "probe", d, overwrite = TRUE)
  got <- DBI::dbGetQuery(con, "
    SELECT md_address_text_id(street, unit, city, state, zip5, zip4) AS a,
           md_release_id(source, version, part) AS r
    FROM probe ORDER BY i")
  expect_identical(got$a, with(d, md_address_text_id(street, unit, city, state, zip5, zip4)))
  expect_identical(got$r, with(d, md_release_id(source, version, part)))
})

test_that("the recipe registry names every tag the code knows", {
  r <- md_id_recipes()
  expect_true(all(c("name.v1", "addr.v1", "rel.v1") %in% r$tag))
  expect_false(anyDuplicated(r$tag) > 0)
})
