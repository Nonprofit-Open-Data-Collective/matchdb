# URLs for a year-partitioned source

URLs for a year-partitioned source

## Usage

``` r
md_source_urls(source, years = NULL)
```

## Arguments

- source:

  A `source` value from
  [`md_sources()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_sources.md)
  whose `years` is set.

- years:

  Integer years, defaulting to the source's full published range.

## Value

A named character vector of URLs, named by year.
