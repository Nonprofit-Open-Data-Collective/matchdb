# Open the matchdb database

`MATCHDB.duckdb` under `db/` in the data root is the relational source
of truth (§7b tier 3). It is the ingest target and the thing publish
reads from; it is not the consumption path for matching.

## Usage

``` r
md_db(read_only = FALSE, path = NULL)

md_db_close(con)
```

## Arguments

- read_only:

  Open read-only. Use for provenance queries.

- path:

  Override the database location.

- con:

  A connection from `md_db()`.

## Value

A DBI connection. Close with `md_db_close()`.
