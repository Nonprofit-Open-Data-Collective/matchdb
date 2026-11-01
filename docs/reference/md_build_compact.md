<div id="main" class="col-md-9" role="main">

# Build the compact identity tables

<div class="ref-description section level2">

Collapses `name` to one row per `(ein, name_key)` and `address` to one
row per `(ein, street_key, city_key, state, zip5)` after domination
pruning. Every contributing raw row is untouched — this is a derived
layer beside `md_build_derived()`'s `name_derived`/`address_derived`,
not a replacement. See `dev/COMPACTION.md` for the process this
implements and what it measured against the real database.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_build_compact(con = NULL, what = c("name", "address"), drop_guarded = TRUE)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A connection from `md_db()`.

-   what:

    Which compact tables to build.

-   drop_guarded:

    Leave out observed names flagged by `md_guard_observed()` and the
    addresses paired with them. Defaults to `TRUE`; a database where the
    guards never ran has no flags and loses nothing.

</div>

<div class="section level2">

## Value

Row counts, invisibly.

</div>

<div class="section level2">

## Why DROP-and-rebuild rather than update in place

If the ranking rule changes, the correct response is `DROP TABLE` and
rebuild, the same posture `md_build_derived()` takes toward normalizer
drift (section 9) — never an in-place reconciliation against tables
meant to stay append-only.

</div>

<div class="section level2">

## Guarded observed rows

`md_guard_observed()` flags observed names written for the wrong EIN
(`name.guard_any`). By default those rows, and the observed addresses
paired with them through `name_id`, are left out **before** collapsing.
A key also backed by an unflagged row (the BMF legal name, say)
survives, carried by that row alone; a key backed only by flagged rows
disappears. Raw rows in `name` and `address` are untouched either way.

With `drop_guarded = FALSE` every row is kept, and `guard_any` on the
compact row is `TRUE` only when **every** row behind it was flagged, so
a spec can still filter on it. In both modes the column exists, so the
table's shape does not depend on the option.

</div>

</div>
