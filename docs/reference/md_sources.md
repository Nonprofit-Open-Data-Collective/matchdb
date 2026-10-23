# The source registry

Every upstream input matchdb ingests, with the URL it comes from. This
is the inventory the build works from; nothing is fetched that is not
listed here.

## Usage

``` r
md_sources()
```

## Value

A `data.frame`, one row per source.

## Details

Note the `pointer` column. Some upstream publishers expose a stable
`latest/` URL whose *contents* change without notice. Those cannot be
cited as provenance - "the BMF as of latest" means nothing six months
on - so
[`md_source_pin()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_source_pin.md)
resolves a pointer to a concrete version before any ingest reads it, and
the ingest reads the pinned copy rather than the URL.
