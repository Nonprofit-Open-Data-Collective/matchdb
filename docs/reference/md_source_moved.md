# Has an upstream pointer moved since we pinned it?

Compares the live `ETag` against a recorded pin. A `TRUE` here means the
upstream file was replaced - not that anything is wrong, but that a
rebuild would produce different data, which is exactly what a pointer
hides.

## Usage

``` r
md_source_moved(source, version)
```

## Arguments

- source:

  A `source` value from
  [`md_sources()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_sources.md).

- version:

  Version directory name, e.g. `"v2026-08-11"`. Defaults to the upstream
  `Last-Modified` date, which is the honest choice for a pointer.

## Value

`TRUE` if upstream differs, `FALSE` if it matches, `NA` if unknown.
