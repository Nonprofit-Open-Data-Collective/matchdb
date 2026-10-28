# Address-sharing statistics for a compiled reference

[`npnormalize::np_addr_freq()`](https://nonprofit-open-data-collective.github.io/npnormalize/reference/np_addr_freq.html),
over exactly the rows of a compiled reference: records per address, per
address and suite, distinct suites per address, suite coverage, distinct
names and the top name's share, and the class.
[`md_publish()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
ships it in every bundle as `addr_freq.parquet`, so a run against a
slice of the reference (a state, a shard) still reads the whole tier's
counts, and
[`md_reference()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
returns it as `addr_freq`, the object `np_compare(addr_freq = )` takes.

## Usage

``` r
md_addr_freq(ref, share_min = 10L, unit_coverage_min = 0.5)
```

## Arguments

- ref:

  A compiled reference frame (`street_key`, `zip5`, `name_key`, and
  `street_unit_id` or `street_unit`).

- share_min, unit_coverage_min:

  npnormalize's thresholds.

## Value

An object of class `np_addr_freq`.
