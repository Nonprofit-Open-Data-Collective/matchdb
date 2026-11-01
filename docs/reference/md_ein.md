<div id="main" class="col-md-9" role="main">

# The canonical EIN format

<div class="ref-description section level2">

Every key in matchdb is an **EIN2** - `EIN-XX-XXXXXXX`, e.g.
`EIN-00-0019818`. This is the stable identifier used across the e-file
data series, the BMF, and the NCCS metadata crosswalks, and matchdb
adopts it so joins across those sources need no conversion step in which
a leading zero can be lost.

`md_is_ein()` tests for the canonical form without converting.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ein(x, to = c("id", "n"), strict = TRUE)

md_is_ein(x)
```

</div>

</div>

<div class="section level2">

## Arguments

-   x:

    Character or numeric vector of EINs in any mixed format -
    `"123456789"`, `"12-3456789"`, `"EIN-12-3456789"`,
    `"ein-12-3456789"`.

-   to:

    `"id"` for `EIN-XX-XXXXXXX`, `"n"` for nine bare digits.

-   strict:

    Return `NA` rather than truncating when the digit count is not nine.
    Defaults to `TRUE`.

</div>

<div class="section level2">

## Value

A character vector, `NA` where the input could not be represented.

</div>

<div class="section level2">

## Details

Leading zeros are the whole reason for the format. `00-0019818` read as
a number is `19818`, and an EIN column that has passed through a
spreadsheet or an untyped CSV read is a well known way to lose
organisations whose EIN begins with zero. A string that cannot be
coerced to a number cannot be silently renumbered.

Semantics follow `ef2::format_ein()`, which is the upstream definition,
with one deliberate difference described below. matchdb does not depend
on ef2 - it is an ETL pipeline rather than a library - so the function
is reimplemented in base R and tested against ef2's documented examples.

</div>

<div class="section level2">

## Strictness

`ef2::format_ein()` strips non-digits and pads to nine characters, then
takes `substr(x, 1, 2)` and `substr(x, 3, 9)`. An input carrying more
than nine digits is therefore **silently truncated**: `"12345678901"`
becomes `"EIN-12-3456789"`, with the trailing digits discarded and no
warning.

For a provenance database that is the wrong default - a mangled
identifier attaches a real organisation's rows to a different EIN, and
nothing downstream can detect it. `md_ein()` therefore returns `NA` for
any input that is not exactly nine digits once punctuation is removed,
and warns with a count. Pass `strict = FALSE` for ef2's truncating
behaviour.

</div>

<div class="section level2">

## Examples

<div class="sourceCode">

``` r
md_ein(c("123456789", "12-3456789", "EIN-12-3456789"))
#> [1] "EIN-12-3456789" "EIN-12-3456789" "EIN-12-3456789"
md_ein("EIN-00-0019818", to = "n")
#> [1] "000019818"
md_ein("19818")                       # padded: EIN-00-0019818
#> [1] "EIN-00-0019818"
suppressWarnings(md_ein("12345678901"))  # NA, not silent truncation
#> [1] NA
```

</div>

</div>

</div>
