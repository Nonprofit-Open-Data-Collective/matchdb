# Compare two frames against the gate criterion

Reports the three counts a phase gate turns on: rows only in the
baseline, rows only in the candidate, and cells that differ on keys
present in both. **The gate passes when all three are zero.**

## Usage

``` r
md_compare_frames(
  baseline,
  candidate,
  columns,
  key = c("ein", "name_key", "street_key", "zip5"),
  n_sample = 10L
)
```

## Arguments

- baseline, candidate:

  Data frames (raw; normal form is applied here).

- columns:

  Pinned comparison columns (see
  [`md_normal_form()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_normal_form.md)).

- key:

  Row-identifying columns.

- n_sample:

  Rows/cells to retain per sample table. Default 10.

## Value

An `md_diff` object: the three counts, three sample tables, and a
per-column tally of differing cells.
