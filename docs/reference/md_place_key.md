<div id="main" class="col-md-9" role="main">

# npnormalize's address key and suite identifier

<div class="ref-description section level2">

`md_place_key()` is npnormalize's address key: the normalized street, a
space, the five-digit ZIP; empty for a PO box, because a box number is
the address and counting records at one counts its owners, not a
building's tenants. `md_unit_id()` is the suite identifier with its
designator and separators dropped ("STE D-2" -> `D2`, "# 300" -> `300`),
so "STE 300", "Suite 300" and "# 300" are one office.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_place_key(street_key, zip5 = NULL)

md_unit_id(unit)
```

</div>

</div>

<div class="section level2">

## Arguments

-   street_key:

    npnormalize's `street_key`.

-   zip5:

    Five-digit ZIP.

-   unit:

    npnormalize's `street_unit` ("STE 300").

</div>

<div class="section level2">

## Value

A character vector.

</div>

<div class="section level2">

## Details

`md_place_key()` calls `npnormalize::np_addr_key()` and `md_unit_id()`
calls `npnormalize::np_unit_id()` (npnormalize 0.1.1 and later; matchdb
requires 0.1.3, whose unit pick changes `street_unit`). The SQL macros
`md_place_key()` and `md_unit_id()` are ports of the same rules; a test
holds them to npnormalize's functions.

</div>

</div>
