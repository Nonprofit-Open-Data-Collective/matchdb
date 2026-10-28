# Publish the database as parquet tranches, fetch only what a spec needs

The database is one 11.7 GB file, but a custom spec reads a small part
of it. `md_publish_tranches()` writes the database as parquet files,
split so that a spec can name the files it needs (`PLAN.md` section 7b,
tier 2). `md_fetch_tranches()` downloads those files and no others.
`md_tranche_db()` opens them as a connection that
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md),
[`md_publish()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
and the lookup functions take in place of
[`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

## Usage

``` r
md_publish_tranches(
  con = NULL,
  root = md_path("tranches"),
  tables = NULL,
  commit = NA_character_,
  set_latest = TRUE
)

md_tranche_pointer(build, root = md_path("tranches"))

md_fetch_tranches(
  spec = NULL,
  tables = NULL,
  build = NULL,
  remote = md_remote(),
  root = md_path("tranches"),
  overwrite = FALSE
)

md_tranche_db(build = NULL, root = md_path("tranches"), verify = TRUE)
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- root:

  The tranche directory. Defaults to `md_data_root()/tranches`.

- tables:

  Tables to publish. The default is every table except the observation
  ledger, which only maintainer code reads.

- commit:

  The matchdb commit the database was built from, recorded in the
  manifest.

- set_latest:

  Point `latest.json` at this build.

- build:

  A build id, e.g. `"2026-10-27-1a2b3c4d"`. By default the one
  `latest.json` names.

- spec:

  An
  [`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md):
  fetch the files
  [`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
  needs for it.

- remote:

  The base URL of a matchdb copy; tranches are under
  `<remote>/tranches/`.

- overwrite:

  Download again even when a file is already here and intact.

- verify:

  Check every local file against its md5 before opening it.

## Value

`md_publish_tranches()`: the build directory, invisibly.

`md_fetch_tranches()`: the local build directory, invisibly.

`md_tranche_db()`: a DBI connection.

## Details

`md_fetch_tranches()` takes a `spec`, a set of `tables`, or both.
`tables` names whole tables (`"orgtext"`, `"ein_relation"`, ...); naming
`"name"` or `"address"` takes every partition with its derived columns,
and `"all"` takes everything. With neither, it takes everything.
`entity` and `source_vintage` always come along. Files already here and
intact are not downloaded again, so fetching for a second spec adds only
what the first did not need.

`md_tranche_db()` opens an in-memory DuckDB holding one view per table,
over whichever files are here. A spec whose files are not all here is an
error from
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
naming them, never a reference built from part of the data. Close it
with
[`md_db_close()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

## The layout

A build is `<root>/<build>/`, and `<root>/latest.json` names the current
one. The build directory holds:

- `name/<layer>/<variant_class>.parquet`:

  the `name` rows of one layer and class, sorted by EIN

- `name_derived/<layer>/<variant_class>.parquet`:

  their derived columns, split the same way

- `address/...`, `address_derived/...`:

  the same for addresses

- `tables/<table>.parquet`:

  every other table, whole, sorted by EIN where it has one

- `manifest.json`:

  the build id, the normalizer signature, the database fingerprint, and
  for every file its table, layer, class, rows, bytes and md5

Derived columns are separate files rather than joined in: `address` and
`address_derived` both have `zip5` and `is_po_box`, with different
meanings, and separate files keep every table exactly as it is in the
database.

## Why layer and class, and not band

Layers partition EINs, and every spec selects by layer and by class, so
a file per layer and class lets a spec skip what it does not select. The
corroboration band is not split out: most of the 32 statistics cells are
small (several under ten rows), and a file per cell would add a download
per cell for no gain.

## What a spec needs

[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
decides each name's class across every class of the selected EINs before
it applies the spec's class filter, so a spec needs all of its layers'
name files except in-care-of names, which compile never reads. It needs
only the address classes it selects. It also needs `entity`,
`source_vintage`, the three statistics tables and the two cluster
tables. Historical addresses (the largest address class, and in no
published tier) are downloaded only by a spec that selects them.

## Examples

``` r
if (FALSE) { # \dontrun{
# maintainer: write the tranches from a built database
md_publish_tranches()

# user: download what one spec needs, and compile it
sp <- md_spec(layers = "bmf_active", names = c("legal", "dba"))
md_fetch_tranches(sp)
con <- md_tranche_db()
r <- md_compile(sp, con)
md_db_close(con)
} # }
```
