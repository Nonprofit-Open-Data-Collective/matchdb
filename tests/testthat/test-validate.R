ok <- data.frame(
  name_id = 1:3,
  ein = c("EIN-13-3039601", "EIN-53-0196605", "EIN-04-2103594"),
  variant_class = c("legal", "legal", "dba"),
  source_vintage = "bmf-2026-08",
  stringsAsFactors = FALSE
)

test_that("a clean table passes every check", {
  v <- md_validate(ok, key = "name_id",
                   enums = list(variant_class = c("legal", "dba", "observed")),
                   required = "source_vintage")
  expect_true(all(v$pass))
})

test_that("a malformed EIN is caught", {
  bad <- ok; bad$ein[2] <- "530196605"
  v <- md_validate(bad, key = "name_id")
  expect_false(v$pass[v$check == "EIN is canonical EIN2"])
})

test_that("a duplicate key is caught", {
  bad <- ok; bad$name_id[3] <- 1L
  v <- md_validate(bad, key = "name_id")
  expect_false(v$pass[v$check == "key is unique"])
})

test_that("missing provenance is caught", {
  bad <- ok; bad$source_vintage[2] <- NA
  v <- md_validate(bad, key = "name_id", required = "source_vintage")
  expect_false(v$pass[v$check == "required source_vintage complete"])
})

test_that("an orphan EIN is caught", {
  v <- md_validate(ok, key = "name_id", parent = c("EIN-13-3039601", "EIN-53-0196605"))
  expect_false(v$pass[v$check == "EIN resolves to entity"])
})

test_that("the report errors on failure when asked", {
  bad <- ok; bad$name_id[3] <- 1L
  v <- md_validate(bad, key = "name_id")
  expect_error(md_validate_report(v), "validation check")
})
