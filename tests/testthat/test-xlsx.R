# The reader is hand-rolled XML parsing, so the cases that matter are the ones
# where the format is not what a naive parse assumes.

make_book <- function(df, path) {
  skip_if_not_installed("openxlsx")
  openxlsx::write.xlsx(df, path)
  path
}

test_that("named columns round-trip, including the ones not asked for", {
  d <- data.frame(Ein = c("010347504", "521148078"),
                  Orgname1 = c("ALPHA TRUST", "BETA FUND"),
                  Secret = c("officer home addr", "another"),
                  Nteecode = c("B11", "E20"),
                  stringsAsFactors = FALSE)
  f <- make_book(d, tempfile(fileext = ".xlsx"))
  out <- md_xlsx_to_csv(f, columns = c("Ein", "Orgname1", "Nteecode"))
  got <- utils::read.csv(out, colClasses = "character")

  expect_equal(names(got), c("Ein", "Orgname1", "Nteecode"))
  expect_equal(got$Orgname1, d$Orgname1)
  expect_equal(got$Nteecode, d$Nteecode)
  # a column not named is never parsed - the disclosure control, not just speed
  expect_false("Secret" %in% names(got))
})

test_that("an empty cell does not shift later columns", {
  # xlsx omits empty cells entirely, so a positional read silently moves every
  # value after a gap one column left. This is the bug that test exists for.
  d <- data.frame(A = c("a1", "a2"), B = c("", "b2"), C = c("c1", "c2"),
                  stringsAsFactors = FALSE)
  f <- make_book(d, tempfile(fileext = ".xlsx"))
  out <- md_xlsx_to_csv(f, columns = c("A", "B", "C"))
  got <- utils::read.csv(out, colClasses = "character", na.strings = NULL)

  expect_equal(got$C, c("c1", "c2"))
  expect_true(got$B[1] %in% c("", NA_character_))
  expect_equal(got$B[2], "b2")
})

test_that("XML-escaped characters come back as themselves", {
  d <- data.frame(N = c("SMITH & JONES", "A <B> C", 'SAY "HI"'),
                  stringsAsFactors = FALSE)
  f <- make_book(d, tempfile(fileext = ".xlsx"))
  out <- md_xlsx_to_csv(f, columns = "N")
  got <- utils::read.csv(out, colClasses = "character")
  expect_equal(got$N, d$N)
})

test_that("a column name that is not in the sheet is an error, not a silent NA", {
  d <- data.frame(A = "x", stringsAsFactors = FALSE)
  f <- make_book(d, tempfile(fileext = ".xlsx"))
  expect_error(md_xlsx_to_csv(f, columns = c("A", "Nope")), "not in the sheet")
})


# Columns past Z are not unit-tested with a fixture: a 70-column workbook is a
# lot of scaffolding for one regex. They are exercised by the real 1023-EZ
# approvals file, where Nteecode is column 69 (BQ) and extracts at 100% fill.
