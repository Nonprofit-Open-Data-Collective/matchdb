test_that("md_modal_sql picks the most frequent value", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "t", data.frame(
    g = c("a","a","a","b","b"),
    v = c("x","x","y","p","q"), stringsAsFactors = FALSE))
  q <- sprintf("WITH %s SELECT g, v FROM modal_v WHERE rk = 1 ORDER BY g",
               md_modal_sql("t", "g", "v"))
  got <- DBI::dbGetQuery(con, q)
  expect_equal(got$v[got$g == "a"], "x")          # 2 vs 1
  expect_equal(got$v[got$g == "b"], "p")          # tie -> alphabetical
})

test_that("ties resolve the same way every time", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # every value appears once, so every group is a total tie
  DBI::dbWriteTable(con, "t", data.frame(
    g = rep(letters[1:6], each = 4),
    v = as.character(seq_len(24)), stringsAsFactors = FALSE))
  q <- sprintf("WITH %s SELECT g, v FROM modal_v WHERE rk = 1 ORDER BY g",
               md_modal_sql("t", "g", "v"))
  runs <- replicate(5, paste(DBI::dbGetQuery(con, q)$v, collapse = "|"))
  expect_equal(length(unique(runs)), 1L)
})

test_that("an empty string is a candidate like any other, not special-cased", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # '' twice, 'ST' once: '' wins on frequency, deterministically
  DBI::dbWriteTable(con, "t", data.frame(
    g = c("a","a","a"), v = c("", "", "ST"), stringsAsFactors = FALSE))
  q <- sprintf("WITH %s SELECT v FROM modal_v WHERE rk = 1", md_modal_sql("t", "g", "v"))
  expect_equal(DBI::dbGetQuery(con, q)$v, "")
})

test_that("the frozen enumerations include the 1023-EZ layer", {
  expect_true("approved_only" %in% md_layers())
  expect_length(md_layers(), 5L)
})
