<div id="main" class="col-md-9" role="main">

# Address-sharing statistics for a compiled reference

<div class="ref-description section level2">

`npnormalize::np_addr_freq()`, over exactly the rows of a compiled
reference: records per address, per address and suite, distinct suites
per address, suite coverage, distinct names and the top name's share,
and the class. `md_publish()` ships it in every bundle as
`addr_freq.parquet`, so a run against a slice of the reference (a state,
a shard) still reads the whole tier's counts, and `md_reference()`
returns it as `addr_freq`, the object `np_compare(addr_freq = )` takes.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_addr_freq(ref, share_min = 10L, unit_coverage_min = 0.5)
```

</div>

</div>

<div class="section level2">

## Arguments

-   ref:

    A compiled reference frame (`street_key`, `zip5`, `name_key`, and
    `street_unit_id` or `street_unit`).

-   share_min, unit_coverage_min:

    npnormalize's thresholds.

</div>

<div class="section level2">

## Value

An object of class `np_addr_freq`.

</div>

</div>
