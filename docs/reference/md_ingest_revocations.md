<div id="main" class="col-md-9" role="main">

# Ingest the IRS automatic revocation list

<div class="ref-description section level2">

An organisation that files nothing for three consecutive years loses its
exemption automatically. The list is the record of that: for each EIN,
when it was revoked, when the revocation was posted and, if it happened,
when the exemption was reinstated - dates the BMF does not carry. An EIN
may appear more than once (18,909 twice, 176 three times in the 2026-07
file).

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ingest_revocations(version, con = NULL)
```

</div>

</div>

<div class="section level2">

## Arguments

-   version:

    Pinned `revocations` version, e.g. `"v2026-07"`.

-   con:

    A connection from `md_db()`.

</div>

<div class="section level2">

## Value

Row counts, invisibly.

</div>

<div class="section level2">

## Details

It writes:

-   `entity`:

    EINs in no other source, as `layer = 'revoked_only'` (154,775 in the
    2026-07 file; mostly 501(c)(4)s revoked in 2010 and 2016-2018).

-   `entity_event`:

    `revoked`, `revocation_posted` and `reinstated`, each with its date.
    This is what a temporal veto reads: a grant to an organisation
    revoked years before the grant year is suspect (`REDUCTION.md`
    section 6c).

-   `name`:

    the legal name and DBA as of revocation, `source = 'revocations'`.

-   `address`:

    the address as of revocation, as `historical`: it was true then and
    may not be now.

</div>

</div>
