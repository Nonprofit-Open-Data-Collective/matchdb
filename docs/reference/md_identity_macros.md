# Install the id macros in a DuckDB connection

Defines SQL macros that compute exactly what the R functions in
[md_identity](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_identity.md)
compute, so ingest can hash millions of rows in the database:

## Usage

``` r
md_identity_macros(con)
```

## Arguments

- con:

  A DuckDB connection.

## Value

`con`, invisibly.

## Details

- `md_canon(x)`:

  [`md_canon()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_identity.md).

- `md_hash_id_1(tag, a)` ... `md_hash_id_8(tag, a, ..., h)`:

  [`md_hash_id()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_identity.md)
  with that many fields. DuckDB macros have fixed arity, so there is one
  per field count.

- `md_name_text_id(name_raw)`:

  [`md_name_text_id()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_identity.md).

- `md_address_text_id(street, unit, city, state, zip5, zip4)`:

  [`md_address_text_id()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_identity.md).

- `md_release_id(source, version, partition)`:

  [`md_release_id()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_identity.md).

Temporary macros, so they live as long as the connection and are never
written into `MATCHDB.duckdb`: the recipe's definition stays in this
file.
