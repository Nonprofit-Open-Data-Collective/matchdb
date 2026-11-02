<div id="main" class="col-md-9" role="main">

# npnormalize's address key and suite identifier

<div class="ref-description section level2">

`md_place_key()` is npnormalize's address key: the normalized street, a
space, the five-digit ZIP; empty for any mail-delivery address, because
the key answers *same building?* and none of them is a building. That
covers a PO box (a box number is the address, so counting records at one
counts its owners rather than a building's tenants) and, from
npnormalize 0.1.6, general delivery and military mail. `md_unit_id()` is
the suite identifier with its designator and separators dropped ("STE
D-2" -> `D2`, "# 300" -> `300`), so "STE 300", "Suite 300" and "# 300"
are one office.

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
calls `npnormalize::np_unit_id()`. The SQL macros `md_place_key()` and
`md_unit_id()` apply the same rules over the regex strings
`npnormalize::np_pattern()` publishes (npnormalize 0.1.6 and later; the
place key reads both the `"pobox"` and `"mailonly"` gates), read when
the macros are created, so they cannot hold an older pattern than the
installed npnormalize; a test holds them to npnormalize's functions.

The complement is `npnormalize::np_mail_key()`, stored as the `mail_key`
column: a blanked box still says something, since two organizations
collecting mail from the *same* box are likely administered by the same
people. Weight it with `npnormalize::np_mail_freq()` before believing it
— one BMF box holds 3,626 EINs.

</div>

</div>
