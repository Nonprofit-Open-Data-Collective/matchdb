<div id="main" class="col-md-9" role="main">

# Placeholder EINs

<div class="ref-description section level2">

The R version of the rule `md_guard_observed()` applies in SQL.
Placeholder *names* are npmatch's rule,
`npnormalize::np_name_placeholder()`.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_placeholder_ein(x)
```

</div>

</div>

<div class="section level2">

## Arguments

-   x:

    EINs in any format.

</div>

<div class="section level2">

## Value

Logical; `NA` for EINs that are not nine digits.

</div>

<div class="section level2">

## Examples

<div class="sourceCode">

``` r
md_placeholder_ein(c("000000000", "12-3456789", "EIN-00-0019818", "EIN-53-0196605"))
#> [1]  TRUE  TRUE  TRUE FALSE
```

</div>

</div>

</div>
