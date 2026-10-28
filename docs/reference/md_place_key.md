# npnormalize's address key and suite identifier

`md_place_key()` is npnormalize's address key: the normalized street, a
space, the five-digit ZIP; empty for a PO box, because a box number is
the address and counting records at one counts its owners, not a
building's tenants. `md_unit_id()` is the suite identifier with its
designator and separators dropped ("STE D-2" -\> `D2`, "# 300" -\>
`300`), so "STE 300", "Suite 300" and "# 300" are one office.

## Usage

``` r
md_place_key(street_key, zip5 = NULL)

md_unit_id(unit)
```

## Arguments

- street_key:

  npnormalize's `street_key`.

- zip5:

  Five-digit ZIP.

- unit:

  npnormalize's `street_unit` ("STE 300").

## Value

A character vector.

## Details

`md_place_key()` calls
[`npnormalize::np_addr_key()`](https://nonprofit-open-data-collective.github.io/npnormalize/reference/np_tokenize.html).
`md_unit_id()` calls npnormalize's internal `.np_unit_id()`, and falls
back to a port of the same rule should a later npnormalize rename it.
The SQL macros `md_place_key()` and `md_unit_id()` are ports too; a test
holds them to npnormalize's functions.
