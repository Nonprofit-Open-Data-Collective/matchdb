# Pin a source to a concrete, immutable version

Records what was fetched, from where, and when, into
`sources/<source>/<version>/PIN.dcf`. The pin carries the upstream
`ETag`, `Last-Modified` and byte count, plus the md5 of the local copy
and the `npmatch` normalizer signature current at pin time.

## Usage

``` r
md_source_pin(source, file, version = NULL)

md_source_read_pin(source, version)
```

## Arguments

- source:

  A `source` value from
  [`md_sources()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_sources.md).

- file:

  Path to the already-downloaded local copy.

- version:

  Version directory name, e.g. `"v2026-08-11"`. Defaults to the upstream
  `Last-Modified` date, which is the honest choice for a pointer.

## Value

The pin, invisibly, as a named list.

## Details

The point is not ceremony. `md_ingest_*()` refuses to read a source
directory with no pin, so no row can enter the database whose origin
cannot be named.
