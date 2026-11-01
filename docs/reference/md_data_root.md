<div id="main" class="col-md-9" role="main">

# Where matchdb keeps its data

<div class="ref-description section level2">

The build handles multi-gigabyte sources and produces a database of
similar size, so nothing lives in the package repository.
`md_data_root()` resolves the root in this order: the `MATCHDB_DATA`
environment variable, then `~/Documents/matchdb`.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_data_root()

md_path(..., create = FALSE)

md_data_init(quiet = FALSE)
```

</div>

</div>

<div class="section level2">

## Arguments

-   ...:

    Path components appended to the root.

-   create:

    Create the directory if it does not exist.

-   quiet:

    For `md_data_init()`, do not print the root it set up.

</div>

<div class="section level2">

## Value

A normalized absolute path.

</div>

<div class="section level2">

## Details

The layout under the root is fixed, because provenance depends on it:

-   `sources/<source>/<version>/`:

    one pinned, immutable copy of an upstream file. Never overwritten -
    a new upstream release is a new version directory. See
    `md_source_pin()`.

-   `db/`:

    `MATCHDB.duckdb`, the relational source of truth.

-   `publish/<label>/<spec_hash>/`:

    compiled references (`md_publish()`).

-   `tranches/<build>/`:

    the database as parquet, split by layer and class
    (`md_publish_tranches()`).

-   `logs/`:

    the workspace log: `runs-index.csv` (one row per fetch, compile or
    publish, never rewritten), one detail file per run, and `state.json`
    (what is here now). See `md_log()`.

-   `work/`:

    scratch. Safe to delete; never an input to anything.

</div>

</div>
