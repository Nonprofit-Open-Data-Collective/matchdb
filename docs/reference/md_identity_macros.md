<div id="main" class="col-md-9" role="main">

# Install the id macros in a DuckDB connection

<div class="ref-description section level2">

Defines SQL macros that compute exactly what the R functions in
[md_identity](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_identity.md)
compute, so ingest can hash millions of rows in the database:

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_identity_macros(con)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A DuckDB connection.

</div>

<div class="section level2">

## Value

`con`, invisibly.

</div>

<div class="section level2">

## Details

-   `md_canon(x)`:

    `md_canon()`.

-   `md_hash_id_1(tag, a)` ... `md_hash_id_8(tag, a, ..., h)`:

    `md_hash_id()` with that many fields. DuckDB macros have fixed
    arity, so there is one per field count.

-   `md_name_text_id(name_raw)`:

    `md_name_text_id()`.

-   `md_address_text_id(street, unit, city, state, zip5, zip4)`:

    `md_address_text_id()`.

-   `md_release_id(source, version, partition)`:

    `md_release_id()`.

Temporary macros, so they live as long as the connection and are never
written into `MATCHDB.duckdb`: the recipe's definition stays in this
file.

</div>

</div>
