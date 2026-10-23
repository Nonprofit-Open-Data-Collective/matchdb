# Source-bit registries for `source_mask`

A bitmask computed fresh per compaction run is a hazard: add a source
mid-project and every existing bit shifts. These are frozen registries,
in the same spirit as
[`md_layers()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_layers.md)
(`PLAN.md` section 3a) — a new source appends a new bit; nothing already
assigned ever moves.

## Usage

``` r
md_name_sources()

md_address_sources()
```

## Value

A named integer vector, source name to bit value.
