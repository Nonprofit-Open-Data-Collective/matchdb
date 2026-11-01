<div id="main" class="col-md-9" role="main">

# Has an upstream pointer moved since we pinned it?

<div class="ref-description section level2">

Compares the live `ETag` against a recorded pin. A `TRUE` here means the
upstream file was replaced - not that anything is wrong, but that a
rebuild would produce different data, which is exactly what a pointer
hides.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_source_moved(source, version)
```

</div>

</div>

<div class="section level2">

## Arguments

-   source:

    A `source` value from `md_sources()`.

-   version:

    Version directory name, e.g. `"v2026-08-11"`. Defaults to the
    upstream `Last-Modified` date, which is the honest choice for a
    pointer.

</div>

<div class="section level2">

## Value

`TRUE` if upstream differs, `FALSE` if it matches, `NA` if unknown.

</div>

</div>
