# Read upstream object metadata without downloading it

An HTTP `HEAD`. Used to resolve a `latest/` pointer to something citable
and to detect that an upstream object has been replaced since it was
pinned.

## Usage

``` r
md_source_head(url)
```

## Arguments

- url:

  The object URL.

## Value

A named character vector with `etag`, `last_modified`, `size` and
`status`, or `NULL` if the request failed.
