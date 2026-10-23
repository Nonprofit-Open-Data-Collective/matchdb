# Extract named columns from a large .xlsx by streaming its XML

The IRS publishes the Form 1023-EZ approvals as `.xlsx` only. The 2023
file is 47 MB compressed but **313 MB of sheet XML** over 7.2 million
string cells, and every in-process reader available here dies on it:
[`readxl::read_excel()`](https://readxl.tidyverse.org/reference/read_excel.html)
and DuckDB's `read_xlsx()` both **segfault** rather than erroring. Worth
recording, because a segfault inside a build script reads as a crash
rather than as unsupported input.

## Usage

``` r
md_xlsx_to_csv(xlsx, columns = NULL, out = NULL, sheet = 1L, chunk = 20000L)
```

## Arguments

- xlsx:

  Path to the workbook.

- columns:

  Header names to keep. `NULL` keeps everything, which is only advisable
  on small sheets.

- out:

  Path to write. Defaults to the input with a `.csv` extension.

- sheet:

  Sheet number within the workbook.

- chunk:

  Rows held in memory at once.

## Value

`out`, invisibly.

## Details

So this reads the archive directly. An `.xlsx` is a zip; the sheet is
XML with one `<row>` per record, and cells reference a shared string
table by index.

## Why it takes column names

Extracting all 70-odd columns row by row is slow enough to be unusable -
the work is proportional to cells, and most of those cells are not
wanted. Naming the columns turns the job into one vectorised regex per
column per chunk.

It is also a disclosure control rather than only an optimisation.
Columns 18-57 of the 1023-EZ approvals are five officers' **personal
names and home addresses**. matchdb is a database of organisations;
there is no reason for that data to enter it, and the cheapest way to
guarantee it does not is to never parse those columns.
