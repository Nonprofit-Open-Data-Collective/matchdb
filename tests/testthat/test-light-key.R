# The light key ingests group spellings on (?md_light_key).

test_that("the light key maps accents and & instead of deleting them", {
  skip_if_not_installed("stringi")
  expect_equal(md_light_key("Café"), "CAFE")
  expect_equal(md_light_key("Café"), "CAFE")                       # decomposed accent
  expect_equal(md_light_key("École Française"), "ECOLE FRANCAISE")
  expect_equal(md_light_key("Øresund"), "ORESUND")
  expect_equal(md_light_key("Straße"), "STRASSE")
  expect_equal(md_light_key("Łódź"), "LODZ")
  expect_equal(md_light_key("Æon Trust"), "AEON TRUST")
  expect_equal(md_light_key(c("A & B", "A&B", "A AND B")), rep("A AND B", 3))
  expect_equal(md_light_key("AT&T"), "AT AND T")
})

test_that("the light key still drops punctuation and spacing, and nothing more", {
  skip_if_not_installed("stringi")
  expect_equal(md_light_key("St. Mary's  Church, Inc."), "ST MARYS CHURCH INC")
  expect_equal(md_light_key("Alpha\tTrust\nFund"), "ALPHA TRUST FUND")   # tab is a space, not a join
  expect_equal(md_light_key(c(NA, "", " - ")), c("", "", ""))
  # a misspelling or an abbreviation is the normalizer's business, not this key's
  expect_false(md_light_key("FOUNDATION") == md_light_key("FOUNDAITON"))
  expect_false(md_light_key("ALPHA FDN") == md_light_key("ALPHA FOUNDATION"))
})

test_that("R and SQL compute the same light key", {
  skip_if_not_installed("stringi")
  skip_if_not_installed("duckdb")
  set.seed(20261025)
  pool <- c(letters, LETTERS, 0:9, " ", "  ", "\t", "\n", "&", ".", ",", "'", "-", "/",
            "é", "é", "ñ", "Ø", "ø", "ß", "Æ", "œ",
            "Ł", "đ", "ı", "Þ", " ", "ü", "北", "Ω")
  x <- c("Café & Co", "Øresund", "Straße", "St. Mary's", "",
         vapply(1:2000, function(k) paste(sample(pool, sample(0:20, 1), TRUE), collapse = ""),
                character(1)))
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  .md_light_key_macro(con)
  DBI::dbWriteTable(con, "p", data.frame(i = seq_along(x), x = x, stringsAsFactors = FALSE))
  sql <- DBI::dbGetQuery(con, "SELECT md_light_key(x) AS k FROM p ORDER BY i")$k
  expect_identical(sql, md_light_key(x))
})
