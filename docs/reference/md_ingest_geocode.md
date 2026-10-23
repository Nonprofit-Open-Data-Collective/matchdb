# Attach census geography to the addresses it actually describes

`metadata-address-geocoded` carries census geography - county, CBSA,
tract, block, urban area - plus coordinates, for 3,436,984 EINs.

## Usage

``` r
md_ingest_geocode(con = NULL, path = NULL, version = "2026-08")
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- path:

  Path to the geocoded CSV.

- version:

  Pinned `address_geocoded` version.

## Value

Row counts, invisibly.

## It is one geocode per EIN, not one per address spell

Each row carries a single `ORG_ADDR_FULL` and the `ORG_FISCAL_YEAR` it
came from, and those years run from 1989 to 2024: 62% are 2020 or later,
but 332,621 predate 2000. So the file does not describe "where this
organisation is" - it describes where it was in one particular year.

Attaching it to whichever address row happens to be current would
therefore be wrong for a third of the file. Instead the geocode is
joined back to the address it names, by parsing `ORG_ADDR_FULL` and
matching on `(ein, street, city, state, zip5)`. Rows that match get the
geography; rows that do not are reported and dropped. An unattached
geocode is better than one attached to the wrong address.

## Parsing from the right

`ORG_ADDR_FULL` is comma-joined `street,city,state,zip`, and street
lines contain commas - `"849 ALMAR AVE. STE. C, PMB 217"` is a real
example from the sibling crosswalk. Splitting left-to-right therefore
mis-assigns the fields whenever a street has a comma in it. The last
three fields are always city, state and ZIP, so this splits from the
right and rejoins whatever remains as the street.

## Not all coordinates mean the same thing

`ADDR_TYPE` records what the geocoder actually resolved, and only
1,783,685 of 3,436,986 rows are `PointAddress` - an actual rooftop.
693,034 are `Postal` and 482,890 `PostalExt`, which are **ZIP
centroids**: a point in the middle of a postal area, not the
organisation's location. Treating those as coordinates would put every
organisation in a ZIP at the same spot and make any distance-based
comparison confidently wrong.

So `geocode_type` is stored beside the coordinates rather than
discarded, and any consumer computing distance should filter on it. The
column exists to make that possible; nothing here enforces it.
