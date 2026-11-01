<div id="main" class="col-md-9" role="main">

# The source registry

<div class="ref-description section level2">

Every upstream input matchdb ingests, with the URL it comes from. This
is the inventory the build works from; nothing is fetched that is not
listed here.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_sources()
```

</div>

</div>

<div class="section level2">

## Value

A `data.frame`, one row per source.

</div>

<div class="section level2">

## Details

Note the `pointer` column. Some upstream publishers expose a stable
`latest/` URL whose *contents* change without notice. Those cannot be
cited as provenance - "the BMF as of latest" means nothing six months on
- so `md_source_pin()` resolves a pointer to a concrete version before
any ingest reads it, and the ingest reads the pinned copy rather than
the URL.

</div>

</div>
