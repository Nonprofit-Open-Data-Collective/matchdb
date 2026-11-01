<div id="main" class="col-md-9" role="main">

# Build `ein_key`: every identifier an EIN holds, with how specific it is

<div class="ref-description section level2">

One long table of the keys a matcher can block on, so a hard case can
find candidates through something other than its name: a shared place or
a website. One row per `(ein, kind, key)`.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_build_ein_key(con = NULL)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A connection from `md_db()`.

</div>

<div class="section level2">

## Value

Rows per kind, invisibly.

</div>

<div class="section level2">

## Details

-   `name`:

    `name_key` from `name_compact` - legal, dba, observed and former
    names, without in-care-of names or guarded observed rows

-   `place`:

    `street_key|zip5` from `address_compact`

-   `website`:

    `site_key` from `website`, `kind = 'url'`

-   `email_domain`:

    `site_key` from `website`, `kind = 'email'`

&nbsp;

-   `person`:

    an officer, director or key employee's name key from `person_key`
    (`md_ingest_officers()`), when that table exists

</div>

<div class="section level2">

## How specific a key is

`n_eins_sharing` counts the EINs holding the key, across the whole
database. A key held by one EIN can propose a candidate on its own; a
key held by thousands (`1 WATERFOWL WAY|38120`, `ptk.org`) can only
confirm one found another way.

The whole-database count answers "is this key ambiguous in the
universe". A matcher comparing against a selection of layers needs the
count within the selection, so `md_build_ein_key()` also writes
`ein_key_layer`: the count per `(kind, key, layer)`. Layers partition
EINs - each EIN has exactly one - so the count for any set of layers is
the exact sum of its rows.

</div>

<div class="section level2">

## Rebuild after its inputs

Derived from `name_compact`, `address_compact` and `website`, so it is
rebuilt after them, by DROP and CREATE.

</div>

</div>
