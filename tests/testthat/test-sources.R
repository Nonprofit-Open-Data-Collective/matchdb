test_that("the registry is wellformed", {
  s <- md_sources()
  expect_true(nrow(s) > 0)
  expect_false(any(duplicated(s$source)))
  # every source either has a URL or is explicitly flagged as unrecorded
  unrecorded <- is.na(s$url)
  expect_true(all(grepl("not yet recorded", s$note[unrecorded])))
})

test_that("year-partitioned URLs interpolate", {
  u <- md_source_urls("schedi", 2009:2010)
  expect_length(u, 2)
  expect_match(u[["2009"]], "SI-P02-T01-GRANTS-US-ORGS-GOVTS-2009[.]CSV$")
  expect_error(md_source_urls("bmf_unified"), "not year-partitioned")
})

test_that("a pointer source is flagged as one", {
  s <- md_sources()
  expect_true(s$pointer[s$source == "bmf_unified"])
})
