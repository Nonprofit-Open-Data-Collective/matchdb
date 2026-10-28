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

test_that("joiners are deleted and every other mark separates words, as in npmatch", {
  skip_if_not_installed("stringi")
  # apostrophes and in-word periods are deleted: the BMF holds BOS PLACE, FIND
  expect_equal(md_light_key(c("BO'S PLACE", "BO’S PLACE", "BO´S PLACE", "BO`S PLACE")),
               rep("BOS PLACE", 4))
  expect_equal(md_light_key("F.I.N.D."), "FIND")
  expect_equal(md_light_key("A.B.C.D.E CLUB"), "ABCDE CLUB")
  expect_equal(md_light_key("ST.LUKES"), "STLUKES")
  # a period that already separates words keeps the break
  expect_equal(md_light_key("ST. LUKES"), "ST LUKES")
  expect_equal(md_light_key("ALPHA...BETA"), "ALPHA BETA")
  # every other mark is a space, not a deletion
  expect_equal(md_light_key(c("WINSTON-SALEM ARTS", "WINSTON - SALEM ARTS", "WINSTON SALEM ARTS")),
               rep("WINSTON SALEM ARTS", 3))
  expect_equal(md_light_key("A/B CLUB"), "A B CLUB")
  expect_equal(md_light_key("SMITH,JONES"), "SMITH JONES")
  expect_equal(md_light_key("ALPHA_BETA+GAMMA:DELTA;EPSILON@ZETA"), "ALPHA BETA GAMMA DELTA EPSILON ZETA")
  expect_equal(md_light_key("GROẞE"), "GROSSE")                     # capital eszett
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
  pool <- c(letters, LETTERS, 0:9, " ", "  ", "\t", "\n", "&", ".", ".", ",", "'", "-", "/",
            "’", "´", "`", "ʼ", "ẞ", "_", ":", "(", "\"",
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

test_that("the light key equals npnormalize's own name cleaning", {
  skip_if_not_installed("stringi")
  skip_if_not_installed("npnormalize")
  ns <- asNamespace("npnormalize")
  # the special-letter table arrived in npmatch at 08016b7, before the move to
  # npnormalize, so every npnormalize has it; the check guards a later rename
  skip_if_not(exists(".np_strip_joiners", envir = ns) && exists(".np_special_letters", envir = ns),
              "installed npnormalize lacks the joiner rule or the special-letter table")
  x <- c("BO'S PLACE", "F.I.N.D.", "ST. LUKES", "ST.LUKES", "WINSTON-SALEM ARTS", "A/B CLUB",
         "SMITH,JONES PLAYERS", "(THE) ALPHA", "ALPHA #2", "ALPHA...BETA", "Café & Co",
         "Øresund Trust", "Straße Fund", "Łódź", "Æon", "AT&T",
         "St. Mary's  Church, Inc.", "Alpha\tTrust\nFund", "")
  expect_identical(md_light_key(x), get(".np_basic_clean", envir = ns)(x))
})
