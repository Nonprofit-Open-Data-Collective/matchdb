# Placeholder EINs

The R version of the rule
[`md_guard_observed()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_guard_observed.md)
applies in SQL. Placeholder *names* are npmatch's rule,
[`npnormalize::np_name_placeholder()`](https://nonprofit-open-data-collective.github.io/npnormalize/reference/np_name_core.html).

## Usage

``` r
md_placeholder_ein(x)
```

## Arguments

- x:

  EINs in any format.

## Value

Logical; `NA` for EINs that are not nine digits.

## Examples

``` r
md_placeholder_ein(c("000000000", "12-3456789", "EIN-00-0019818", "EIN-53-0196605"))
#> [1]  TRUE  TRUE  TRUE FALSE
```
