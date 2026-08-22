test_that("md_ein matches ef2::format_ein on its documented examples", {
  expect_equal(md_ein(c("123456789", "987654321")),
               c("EIN-12-3456789", "EIN-98-7654321"))
  expect_equal(md_ein(c("EIN-12-3456789", "EIN-98-7654321"), to = "n"),
               c("123456789", "987654321"))
})

test_that("mixed input formats all resolve to the same key", {
  expect_equal(length(unique(md_ein(c("123456789", "12-3456789",
                                      "EIN-12-3456789", "ein-12-3456789")))), 1L)
})

test_that("leading zeros survive - the reason the format exists", {
  expect_equal(md_ein("19818"), "EIN-00-0019818")
  expect_equal(md_ein(19818), "EIN-00-0019818")
  expect_equal(md_ein("EIN-00-0019818", to = "n"), "000019818")
})

test_that("overlong input is NA rather than silently truncated", {
  expect_warning(r <- md_ein("12345678901"), "more than 9 digits")
  expect_true(is.na(r))
  expect_equal(md_ein("12345678901", strict = FALSE), "EIN-12-3456789")
})

test_that("blank and NA input stay NA", {
  expect_true(all(is.na(md_ein(c(NA, "", "no digits here")))))
})

test_that("md_is_ein recognises the canonical form only", {
  expect_true(md_is_ein("EIN-00-0019818"))
  expect_false(md_is_ein("000019818"))
  expect_false(md_is_ein("ein-00-0019818"))
  expect_false(md_is_ein(NA))
})
