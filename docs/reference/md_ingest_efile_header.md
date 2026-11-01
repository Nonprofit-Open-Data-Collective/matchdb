<div id="main" class="col-md-9" role="main">

# Ingest the 990 filing header as self-reported names and addresses

<div class="ref-description section level2">

`F9-P00-T00-HEADER` is one row per Form 990 filing, 2009-2024, carrying
the organisation's own name, DBA, in-care-of line and mailing address
**as it wrote them on that year's return**.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ingest_efile_header(version = "v2_2", con = NULL)
```

</div>

</div>

<div class="section level2">

## Arguments

-   version:

    Pinned `efile_header` version, e.g. `"v2_2"`.

-   con:

    A connection from `md_db()`.

</div>

<div class="section level2">

## Value

Row counts, invisibly.

</div>

<div class="section level2">

## What makes this different from the BMF

The BMF holds one current name per EIN. This holds one per filing year,
so it is the first source here that can show a name *changing*. That is
what makes `variant_class = 'former'` derivable rather than
aspirational: within an EIN, the spelling carried by the most recent
filing is `legal` and every earlier distinct spelling is `former`, which
is exactly the definition in section 3a.

</div>

<div class="section level2">

## What is deliberately not ingested

`F9_00_PRIN_OFF_*` looks like a principal *office* address and is not -
it is the principal **officer**, as the neighbouring
`F9_00_PRIN_OFF_NAME_PERS` makes plain. Those rows are a natural
person's name and address, and where the officer is an organisation it
is a *different* organisation from the filer, so attaching its address
to the filer's EIN would be wrong on top of intrusive.

A consequence worth stating: `address.variant_class = 'principal'` stays
empty after this ingest. The 990 header does not publish a
principal-office address distinct from the mailing address, and an empty
class is a more honest answer than one filled with somebody's home
address.

</div>

</div>
