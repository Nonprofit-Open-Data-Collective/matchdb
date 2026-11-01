<div id="main" class="col-md-9" role="main">

# The natural key of each source

<div class="ref-description section level2">

What identifies one record in each source, so an observation's id
(`dev/IDENTITY.md` §3) can be computed from the raw file and stays the
same across re-releases. Phase 5 step 2.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_record_keys()
```

</div>

</div>

<div class="section level2">

## Value

A data frame, one row per source in `md_sources()`.

</div>

<div class="section level2">

## Details

Columns:

-   `source`, `kind`:

    As in `md_sources()`.

-   `filing_key`:

    The column(s) naming one filing or one record: `OBJECTID` for e-file
    tables, `FORM_ID_NUMBER` for Form 8871, the EIN for one-row-per-EIN
    files.

-   `grain`:

    `record`: `filing_key` alone is unique. `row`: a filing has many
    rows (one per grant, related organisation, officer), so a row is
    identified by `filing_key` plus a hash of its fields plus an
    occurrence counter among identical rows. Identical rows inside one
    return are real - the 2022 Schedule I sample has 11 in 4,646 - and
    the counter keeps them apart.

-   `trace_key`:

    A publisher's row identifier stored with each observation for
    tracing by hand, but **not** hashed into its id: e-file `TABLE_ID`
    is the row's position in the return, and a parser change could
    renumber it, while the row's content cannot change.

-   `period`:

    The column giving the observation's year, if any.

-   `asserted_by`:

    For a third-party source, the column naming who wrote the row (the
    filer).

-   `latest_by`:

    For sources with amended returns: count only the filing with the
    greatest value of this column per (filer, period) - the latest
    return (`dev/IDENTITY.md` §9, decided 2026-10-24).

-   `evidence`:

    How the key was confirmed.

Confirmed on the first 2 MB of each 2022 e-file table and of the 2026-07
e-Postcard and revocation files, downloaded 2026-10-24. A sample can
show a key is *not* unique but cannot prove it is, so
`md_check_record_key()` runs the same test on a whole file at ingest.

</div>

</div>
