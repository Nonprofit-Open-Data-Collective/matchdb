<div id="main" class="col-md-9" role="main">

# Open the matchdb database

<div class="ref-description section level2">

`MATCHDB.duckdb` under `db/` in the data root is the relational source
of truth (§7b tier 3). It is the ingest target and the thing publish
reads from; it is not the consumption path for matching.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_db(read_only = FALSE, path = NULL)

md_db_close(con)
```

</div>

</div>

<div class="section level2">

## Arguments

-   read_only:

    Open read-only. Use for provenance queries.

-   path:

    Override the database location.

-   con:

    A connection from `md_db()`.

</div>

<div class="section level2">

## Value

A DBI connection. Close with `md_db_close()`.

</div>

</div>
