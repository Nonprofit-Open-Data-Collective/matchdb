<div id="main" class="col-md-9" role="main">

# Read upstream object metadata without downloading it

<div class="ref-description section level2">

An HTTP `HEAD`. Used to resolve a `latest/` pointer to something citable
and to detect that an upstream object has been replaced since it was
pinned.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_source_head(url)
```

</div>

</div>

<div class="section level2">

## Arguments

-   url:

    The object URL.

</div>

<div class="section level2">

## Value

A named character vector with `etag`, `last_modified`, `size` and
`status`, or `NULL` if the request failed.

</div>

</div>
