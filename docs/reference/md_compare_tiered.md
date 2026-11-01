<div id="main" class="col-md-9" role="main">

# Compare two tiered benchmark outputs

<div class="ref-description section level2">

Stricter than `md_compare_frames()` and shaped differently, because
tiered results do **not** share an identity set across references: the
frame carries one row per identity that drew at least one candidate, and
a larger reference reaches more of them (4,733 identities on the monthly
BMF against 4,793 on the augmented one —
`pfmatch/dev/VARIANT-CLASS-AB.md`).

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_compare_tiered(
  baseline,
  candidate,
  columns = c(".id", "overall_ein", "tier", "decision_score"),
  n_sample = 10L
)
```

</div>

</div>

<div class="section level2">

## Arguments

-   baseline, candidate:

    Tiered result frames (`np_tiered` or plain).

-   columns:

    Columns compared. Default the verdict-bearing four.

-   n_sample:

    Rows to retain in the sample table. Default 10.

</div>

<div class="section level2">

## Value

An `md_diff` object.

</div>

<div class="section level2">

## Details

So align on the union of `.id` and mark an absent identity `NONE`, which
is distinct from a scored `NO`: no candidate was ever generated, rather
than one generated and rejected. Comparing without this reports phantom
differences.

</div>

</div>
