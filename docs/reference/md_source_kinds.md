# The kinds of source

Every source in
[`md_sources()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_sources.md)
has a `kind`, which decides how a new release of it changes the database
and what one observation of it means (`dev/IDENTITY.md` section 2):

## Usage

``` r
md_source_kinds()
```

## Value

A character vector of kinds.

## Details

- `cache`:

  Compiled once; a new release is a correction. One observation is one
  row as delivered. A new release is diffed as a whole file.

- `snapshot`:

  Republishes the current state, one row per EIN, overwriting old values
  (the monthly BMF, the e-Postcard). One observation is a spell: an
  unbroken run of releases with the same value.

- `seed`:

  A snapshot that has already been folded into one row per EIN
  (`bmf_unified`). Loaded once; its date ranges bound the EIN, not the
  value.

- `series`:

  An organisation describing itself once per period (the 990 header,
  1023-EZ), or a cumulative list re-pulled whole. One observation is one
  period; corroboration is how many periods a value appeared in.

- `mentions`:

  Third parties writing about an organisation as often as they like
  (Schedule I grants, Schedule R). One observation is one row, repeats
  included; corroboration is how many times, and by how many filers.

"Snapshot" rather than "roster": in this package a roster is a
group-return roster
([`md_ingest_affiliate_listing()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_affiliate_listing.md)).
