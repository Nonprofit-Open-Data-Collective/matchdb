test_that("the registry is wellformed", {
  s <- md_sources()
  expect_true(nrow(s) > 0)
  expect_false(any(duplicated(s$source)))
  expect_true(all(s$origin %in% c("remote", "local", "derived", "unrecorded")))
  # a remote source has a URL; a local one does not
  expect_true(all(!is.na(s$url[s$origin == "remote"])))
  expect_true(all(is.na(s$url[s$origin != "remote"])))
  # a real gap says so; local and derived entries are not gaps and need not
  expect_true(all(grepl("not yet recorded", s$note[s$origin == "unrecorded"])))
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

test_that("every source has a kind, and only bmf_unified is a seed", {
  s <- md_sources()
  expect_true(all(s$kind %in% md_source_kinds()))
  expect_equal(s$source[s$kind == "seed"], "bmf_unified")
  expect_equal(sort(s$source[s$kind == "snapshot"]), c("bmf_active", "e_postcard"))
})

# Pins for a source with no URL, so nothing goes to the network.
with_pin_root <- function(code) {
  root <- tempfile("mdroot"); dir.create(root)
  old <- Sys.getenv("MATCHDB_DATA", unset = NA)
  Sys.setenv(MATCHDB_DATA = root)
  on.exit({
    if (is.na(old)) Sys.unsetenv("MATCHDB_DATA") else Sys.setenv(MATCHDB_DATA = old)
    unlink(root, recursive = TRUE)
  })
  force(code)
}

test_that("a single-file pin records its file in FILES.csv", {
  skip_if_not_installed("npnormalize")
  with_pin_root({
    dir <- md_path("sources", "ntee_crosswalk", "v1", create = TRUE)
    f <- file.path(dir, "ntee.csv"); writeLines("a,b", f)
    md_source_pin("ntee_crosswalk", f, version = "v1")
    got <- md_source_read_files("ntee_crosswalk", "v1")
    expect_equal(got$file, "ntee.csv")
    expect_equal(got$md5, unname(tools::md5sum(f)))
    expect_equal(got$md5, md_source_read_pin("ntee_crosswalk", "v1")$local_md5)
  })
})

test_that("a set pin records each file, so a changed year can be found", {
  skip_if_not_installed("npnormalize")
  with_pin_root({
    dir <- md_path("sources", "ntee_crosswalk", "v-set", create = TRUE)
    f <- file.path(dir, c("Y-2021.csv", "Y-2020.csv"))
    writeLines("x", f[1]); writeLines("y", f[2])
    md_source_pin("ntee_crosswalk", f, version = "v-set")
    before <- md_source_read_files("ntee_crosswalk", "v-set")
    expect_equal(before$file, c("Y-2020.csv", "Y-2021.csv"))    # sorted

    writeLines("x, revised", f[1])
    md_source_pin("ntee_crosswalk", f, version = "v-set")
    after <- md_source_read_files("ntee_crosswalk", "v-set")
    changed <- after$file[after$md5 != before$md5]
    expect_equal(changed, "Y-2021.csv")
  })
})

test_that("a pin written before FILES.csv existed reads as NULL", {
  with_pin_root({
    expect_null(md_source_read_files("ntee_crosswalk", "v-old"))
  })
})
