<div id="main" class="col-md-9" role="main">

# Fold one release of a source into the ledger

<div class="ref-description section level2">

Takes a parsed release - a table or view with the standard frame columns
(see the `md_parse_*()` functions) - and applies the update rule for the
source's kind (`md_source_kinds()`), in one transaction:

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_apply_release(
  con,
  frame,
  source,
  version,
  part = NA,
  vintage = version,
  file_md5 = NA
)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A DuckDB connection holding the ledger.

-   frame:

    A table or view in `con` with the standard frame columns.

-   source:

    A source from `md_sources()`.

-   version:

    The pinned version.

-   part:

    The partition (tax year), or `NA`.

-   vintage:

    What the release describes, as a sortable string (`"2026-07"`).
    Defaults to `version`. Orders snapshot releases.

-   file_md5:

    The md5 of the file read. If a release with this id was already
    applied from a file with the same md5, nothing is done.

</div>

<div class="section level2">

## Value

A one-row data frame, invisibly: `status` (`applied`, `unchanged` or
`already_applied`), `n_rows`, `n_new`, `n_kept`, `n_retracted`.

</div>

<div class="section level2">

## Details

-   series, mentions, cache, seed:

    Diff against the ledger rows of this source and partition: new rows
    are inserted, rows already present have `last_release` moved to this
    release, and rows this release no longer carries get `retracted_in`.
    A retracted row that comes back is un-retracted. A new partition is
    all inserts.

-   snapshot:

    Compare against the spells left open by the source's previous
    release: an unchanged value extends its spell, a new or changed
    value opens one, and a value that is missing is left closed.
    Releases must arrive in vintage order; an older one is refused,
    because the fix for a missed release is a replay, not a back-fill.

Applying the same release twice changes nothing. For a snapshot, the
second application is reported as already applied; for the other kinds
the diff simply finds nothing to do.

</div>

</div>
