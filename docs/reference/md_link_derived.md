# Rebuild name_derived and address_derived from the text-keyed columns

After
[`md_install_rollups()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_rollup.md),
every `name` and `address` row names the spelling it shows
(`name_text_id`, `address_text_id`), whose derived columns
[`md_build_text_derived()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_text.md)
stored once. This writes `name_derived` and `address_derived`, keyed on
the integer ids compile joins on, by a join - seconds, against the hour
[`md_build_derived()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_build_derived.md)
takes to normalize every row. A spelling with no derived row for the
signature is an error, not a gap.

## Usage

``` r
md_link_derived(con, signature = npnormalize::np_normalize_signature())
```

## Arguments

- con:

  A DuckDB connection.

- signature:

  The normalizer signature to read. Defaults to the installed npmatch's.

## Value

Row counts, invisibly.
