<div id="main" class="col-md-9" role="main">

# Ingest the Form 990-N e-Postcard

<div class="ref-description section level2">

The e-Postcard is the only filing the smallest organisations make: gross
receipts normally under $50,000, no full 990, so no e-file table ever
sees them. For 834,305 of its EINs the BMF was the only source of a name
before this ingest.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ingest_e_postcard(version, con = NULL)
```

</div>

</div>

<div class="section level2">

## Arguments

-   version:

    Pinned `e_postcard` version, e.g. `"v2026-07"`.

-   con:

    A connection from `md_db()`.

</div>

<div class="section level2">

## Value

Row counts, invisibly.

</div>

<div class="section level2">

## Details

The NCCS file holds **one row per EIN, its latest postcard** (tax years
2007-2025 in the 2026-07 file), so it gives a current address, not an
address history. It writes:

-   `entity`:

    EINs in no other source, as `layer = 'postcard_only'` (73,503 in the
    2026-07 file).

-   `name`:

    the legal name and up to three DBAs, `source = 'e_postcard'`, with
    the postcard's tax year as `first_year` and `last_year`.

-   `address`:

    the organisation's address as `mailing`, as of that year.

-   `entity_event`:

    `terminated_990n` where the postcard says the organisation has
    terminated, dated by the end of its tax period.

The officer name and address are not read: they describe a person. The
website field is read by `md_ingest_websites()`.

</div>

</div>
