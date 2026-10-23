# Ingest the resolved address crosswalk as historical spells

`address_resolved_crosswalk` is the NCCS address history: 11,299,800
rows over 3,687,468 EINs, each row one *spell* an organisation occupied
an address, with `spell_rank`, the vintage range it spans, and how many
vintages observed it.

## Usage

``` r
md_ingest_address_crosswalk(con = NULL, path = NULL, version = "2026-08")
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- path:

  Path to the crosswalk CSV.

- version:

  Pinned `address_crosswalk` version.

## Value

Row count, invisibly.

## Details

It supersedes parsing `metadata-addresses`, whose `ORG_ADDRESS_ALL` is a
comma-joined string that collides with commas inside street lines
([`?md_meta_caveats`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_meta_caveats.md)).
This file has already done that parse.

## Everything here is historical, including spell_rank 0

Every row enters as `variant_class = 'historical'`, and that is a
deliberate choice rather than an oversight about rank 0. The crosswalk
is an archive of where organisations have been; its most recent spell is
not guaranteed to be where they are now, and its `last_vintage` can be
years old. The BMF supplies the current mailing address, and letting a
stale spell claim `mailing` would put a reference to work matching
organisations to addresses they have left.

`spell_rank` and `last_vintage` are both carried, so a consumer that
wants "most recent spell, still current as of a recent vintage" can
express it - but has to say so.

## Two shape facts worth knowing before selecting this

**Street is present on only 61.2% of rows.** The remainder carry city,
state and ZIP but no street line. Those are still real geography and
still block on ZIP, so they are loaded rather than discarded, but a spec
that assumes a street on every historical address will be disappointed
on four rows in ten.

**This roughly triples the address table.** It is the largest single
source in the database. That is the intended shape - the database holds
everything and the spec selects (section 5) - but it makes the section 8
row budget a live concern at compile time rather than a theoretical one.

## A parsing hazard, recorded

DuckDB's CSV sniffer mis-detects this file, inferring no quote
character, so a street like `"849 ALMAR AVE. STE. C, PMB 217"` splits
into fourteen columns against a thirteen-column header and the read
fails. The error text suggests `ignore_errors=true`, which would
silently drop every row containing a comma in its street - precisely the
rows most worth having. The fix is to state the quote character rather
than let it be guessed.
