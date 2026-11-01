<div id="main" class="col-md-9" role="main">

# Compare two frames against the gate criterion

<div class="ref-description section level2">

Reports the three counts a phase gate turns on: rows only in the
baseline, rows only in the candidate, and cells that differ on keys
present in both. **The gate passes when all three are zero.**

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_compare_frames(
  baseline,
  candidate,
  columns,
  key = c("ein", "name_key", "street_key", "zip5"),
  n_sample = 10L
)
```

</div>

</div>

<div class="section level2">

## Arguments

-   baseline, candidate:

    Data frames (raw; normal form is applied here).

-   columns:

    Pinned comparison columns (see `md_normal_form()`).

-   key:

    Row-identifying columns.

-   n_sample:

    Rows/cells to retain per sample table. Default 10.

</div>

<div class="section level2">

## Value

An `md_diff` object: the three counts, three sample tables, and a
per-column tally of differing cells.

</div>

</div>
