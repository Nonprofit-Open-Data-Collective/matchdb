# The IRS names the 1023-EZ workbooks three ways. The year is what names the
# converted CSV, so a wrong year silently merges or drops whole years.

test_that("the year is read from before .xlsx under every IRS convention", {
  books <- c("f1023ez_approvals_2014.xlsx", "f1023EZ_approvals_2017.xlsx",
             "f1023ez-approvals-2020.xlsx", "dir/f1023ez-approvals-2023.XLSX")
  # the 1023 in the form name must not be taken for a year
  expect_equal(.md_f1023ez_year(books), c("2014", "2017", "2020", "2023"))
})

test_that("a workbook name with no year is an error, not a guess", {
  expect_error(.md_f1023ez_year("f1023ez-approvals.xlsx"), "no year before .xlsx")
})
