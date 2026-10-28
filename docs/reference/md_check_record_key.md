# Check a source's natural key on a loaded file

The Phase 5 step 2 check, run on a whole file rather than a sample: is
the key in
[`md_record_keys()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_record_keys.md)
unique? For a `record` source the filing key must be unique. For a `row`
source, rows repeating the same filing key **and** the same content are
counted as repeats: they are legitimate (two identical grants), and the
occurrence counter is what tells them apart, but the count is reported
so a jump in it is visible.

## Usage

``` r
md_check_record_key(con, relation, source)
```

## Arguments

- con:

  A DuckDB connection.

- relation:

  A table, view or `read_csv(...)` expression holding the raw file, with
  the source's own column names.

- source:

  A source from
  [`md_record_keys()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_record_keys.md).

## Value

A one-row data frame: `source`, `grain`, `n_rows`, `n_keys`,
`n_repeats`, `ok`. `ok` is `FALSE` only for a `record` source whose key
repeats.
