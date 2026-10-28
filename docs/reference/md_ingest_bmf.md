# Ingest the unified BMF into entity, name and address

Reads the pinned BMF parquet and writes its rows into the three core
tables. Idempotent: re-running replaces the BMF's own rows rather than
accumulating, and leaves every other source's rows alone, so a newer BMF
can be loaded into a database that already holds Schedule I, the return
headers and the rest.

## Usage

``` r
md_ingest_bmf(version, con = NULL, validate = TRUE)

md_validate_bmf(con)
```

## Arguments

- version:

  The pinned `bmf_unified` version, e.g. `"v2026-08-11"`.

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).
  Opened and closed here if `NULL`.

- validate:

  Run
  [`md_validate()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_validate.md)
  on each table and stop on failure.

## Value

A named vector of the BMF's own row counts, invisibly.

## What this does and does not populate

The BMF is a snapshot, not a panel (§4), so this fills the identity
spine and the *current* name and address. It writes the
resolved-attribute columns as `NULL` and leaves them for
[`md_ingest_ntee()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_ntee.md),
which reads the canonical NTEE crosswalk - the only source that can
supply the rule and the agreement flag the triple requires. The BMF's
own `ntee_code_raw` is carried through so the recomputation has its
input, but the BMF's `nteev2` rendering is deliberately **not** copied:
it carries the specialty double-encoding defect
([`?md_ntee_canonical`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ntee_canonical.md)).

## Layer assignment

`bmf_active` means "in the current active BMF release" (§3a), which in
this file is `last_vintage_ym` equal to the newest vintage present.
Everything else is `bmf_inactive`. `status_code` is carried separately
rather than conflated with layer, because status is mutable and layer is
provenance (§4).

## Loading into a database that already has other sources

This used to `CREATE OR REPLACE` all three tables, which deleted every
other source's rows and made the BMF loadable only as the first step of
a fresh build. It now deletes and re-inserts only its own rows, in one
transaction:

- `name` and `address`: rows with `source = 'bmf'`.

- `entity`: rows from any earlier BMF load, plus any row an earlier
  ingest wrote for an EIN this file contains. The BMF is the identity
  spine, so its row replaces a `filer_only`, `approved_only` or other
  placeholder for the same EIN.

- An EIN that an earlier BMF load had but this file does not, and that
  another source's `name`, `address` or `entity_event` row still refers
  to, is put back with the layer a fresh build would give it: that of
  the earliest-built source still naming it (`approved_only` for
  1023-EZ, `filer_only` for the 990 filings and schedules,
  `postcard_only`, `revoked_only`). No row is left pointing at a missing
  entity.

Replaced rows lose whatever later steps wrote onto them, and the new BMF
rows get new `name_id`/`address_id` values. After a re-ingest, re-run
the steps that follow the ingests in `dev/build-matchdb.R` (NTEE,
geocode, guards, derived columns with `incremental = TRUE`, compaction,
groups, keys, clusters, statistics). The ingest prints this reminder
when it replaced anything.
