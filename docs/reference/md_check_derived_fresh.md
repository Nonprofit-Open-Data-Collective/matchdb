<div id="main" class="col-md-9" role="main">

# Has a re-ingest invalidated the derived tables?

<div class="ref-description section level2">

`md_ingest_*()` functions are idempotent by deleting their own source's
rows and re-inserting, and the re-inserted rows get **freshly assigned**
ids — `base_id <- max(id)` at insert time, not a content-stable key. So
any re-ingest, however small the actual change, invalidates every
`name_id` / `address_id` the derived tables were built against, and
`name_derived`'s `LEFT JOIN` degrades silently rather than erroring: it
just matches fewer rows every time.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_check_derived_fresh(con, stop_on_stale = TRUE)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A connection from `md_db()`.

-   stop_on_stale:

    Error rather than warn when orphans are found.

</div>

<div class="section level2">

## Value

Invisibly, a two-row data frame of orphan counts.

</div>

<div class="section level2">

## Details

This was found, not anticipated: two backfill re-runs during Phase 0
development left `name_derived` matching only 6,052,242 of 9,662,561
name rows — every row except the untouched BMF ones — and a compaction
pass built on top of it silently lost every `observed`/`former` name and
every EIN outside the BMF, with no error at any step. See
`PAIN-POINTS.md`.

Call this before anything joins to `name_derived`/`address_derived`, not
only right after ingest — a re-ingest run by someone else, or an earlier
session, leaves no other trace.

</div>

</div>
