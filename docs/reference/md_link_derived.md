<div id="main" class="col-md-9" role="main">

# Rebuild name_derived and address_derived from the text-keyed columns

<div class="ref-description section level2">

After `md_install_rollups()`, every `name` and `address` row names the
spelling it shows (`name_text_id`, `address_text_id`), whose derived
columns `md_build_text_derived()` stored once. This writes
`name_derived` and `address_derived`, keyed on the integer ids compile
joins on, by a join - seconds, against the hour `md_build_derived()`
takes to normalize every row. A spelling with no derived row for the
signature is an error, not a gap.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_link_derived(con, signature = npnormalize::np_normalize_signature())
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A DuckDB connection.

-   signature:

    The normalizer signature to read. Defaults to the installed
    npmatch's.

</div>

<div class="section level2">

## Value

Row counts, invisibly.

</div>

</div>
