# Where matchdb keeps its data

The build handles multi-gigabyte sources and produces a database of
similar size, so nothing lives in the package repository.
`md_data_root()` resolves the root in this order: the `MATCHDB_DATA`
environment variable, then `~/Documents/matchdb`.

## Usage

``` r
md_data_root()

md_path(..., create = FALSE)

md_data_init(quiet = FALSE)
```

## Arguments

- ...:

  Path components appended to the root.

- create:

  Create the directory if it does not exist.

## Value

A normalized absolute path.

## Details

The layout under the root is fixed, because provenance depends on it:

- `sources/<source>/<version>/`:

  one pinned, immutable copy of an upstream file. Never overwritten - a
  new upstream release is a new version directory. See
  [`md_source_pin()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_source_pin.md).

- `db/`:

  `MATCHDB.duckdb`, the relational source of truth.

- `publish/<label>/<spec_hash>/`:

  compiled references
  ([`md_publish()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)).

- `tranches/<build>/`:

  the database as parquet, split by layer and class
  ([`md_publish_tranches()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish_tranches.md)).

- `logs/`:

  the workspace log: `runs-index.csv` (one row per fetch, compile or
  publish, never rewritten), one detail file per run, and `state.json`
  (what is here now). See
  [`md_log()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_log.md).

- `work/`:

  scratch. Safe to delete; never an input to anything.
