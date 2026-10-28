# Parquet tranches: the database, fetched by the piece

**Built 2026-10-27.** Code: `R/md-tranches.R`. Tests:
`tests/testthat/test-tranches.R`. Full-scale check: `dev/verify/tranche-check.R`,
log in `dev/verify/logs/tranche-check-2026-10-27.log`. This is `PLAN.md`
§7b's tier 2.

## Why

Users had two choices:
* a compiled bundle (230–400 MB), for one of the four named tiers;
* the whole database (11.7 GB), for anything else.

A custom spec reads a small part of the database. Tranches publish it as
parquet files split so that a spec can name the files it needs, and download
only those.

## The three functions

* `md_publish_tranches()` (maintainer) writes `<root>/<build>/` and points
  `<root>/latest.json` at it.
* `md_fetch_tranches(spec, tables)` downloads the files a spec needs, plus any
  whole tables named, checking each against its md5. Files already present and
  intact are skipped, so a second spec downloads only the difference.
* `md_tranche_db()` opens an in-memory DuckDB with one view per table over the
  files present. The views are named after the database's own tables, so
  `md_compile()`, `md_publish()`, `md_lookup()` and `md_cluster()` run on it
  unchanged.

## Layout

```
<build>/
  manifest.json                      build, signature, fingerprint; per file: table, layer, class, rows, bytes, md5
  name/<layer>/<class>.parquet       sorted by ein, name_id
  name_derived/<layer>/<class>.parquet
  address/<layer>/<class>.parquet    sorted by ein, address_id
  address_derived/<layer>/<class>.parquet
  tables/<table>.parquet             every other table, whole; sorted by ein where it has one
```

The build id is the date plus a hash of the file md5s. Builds are never
overwritten: rolling back means editing `latest.json` (`md_tranche_pointer()`).
The observation ledger is left out, as in the user copy of the database.

## Decisions

* **Split by layer and class, not by band.** Layers partition EINs, and every
  spec selects by layer and class. Band is not split out because the 32
  statistics cells are very uneven: the largest has 2.28M rows, and several
  have fewer than ten. A file per cell would add a request per cell and gain
  nothing. §7b's rule still holds in its useful form: each file is the union
  of its band cells, and no cell spans two files.
* **Derived columns in their own files, split the same way.** This changes
  what I first proposed (joining them in). `address` and `address_derived`
  both have `zip5` and `is_po_box`, with different meanings. Separate files
  keep every table exactly as it is in the database, so the views need no
  renaming. It costs one extra request per partition.
* **What a spec needs** (`.md_tranche_need()`, used by both the fetch and
  compile's guard):
  * Names: compile decides each name's class across every class of the
    selected EINs, then filters by the spec. That class also decides sums
    such as `n_obs` and the modal spelling. So a spec needs all of its layers'
    name files except in-care-of names, which compile never reads.
  * Addresses: only the classes the spec selects.
  * Always: `entity`, `source_vintage`, the three statistics tables and the
    two cluster tables.
* **A partial connection refuses a wider spec.** `md_tranche_db()` records
  which files are present. `md_compile()` errors, naming the missing files,
  when a spec needs one it does not have, rather than compiling from part of
  the data.
* **Checks match the bundles.** md5 on fetch and on open (`verify = TRUE`:
  8.5 s for all 4.6 GB). The normalizer signature is checked against the
  installed npmatch on both.

## Measured, 2026-10-27

Built from the release database (`main` at `592b078`, npmatch `26a5910`).

**The build:** 108 files, 4.64 GB, 197M rows. It took 7.9 min on the first
run and 2.0 min on the second, once the database was in the disk cache. The
largest tables:

| table | size |
|---|---:|
| `address` | 1.37 GB (historical addresses 0.77 GB of it) |
| `name` | 0.72 GB |
| `orgtext` | 0.45 GB |
| `address_derived` | 0.42 GB |
| `ein_key` | 0.40 GB |
| `name_derived` | 0.33 GB |

**Compiling a tier from its own tranches** (fetched over `file://`):

| tier | files | download | open, verify, compile | compared with the bundle |
|---|---:|---:|---:|---|
| `active-legal` | 18 | 1.03 GB | 0.9 min | 2,742,924 rows; frame, `name_freq`, `token_idf`, fingerprint identical |
| `active-observed` | 20 | 1.18 GB | 0.9 min | 2,885,032 rows; identical |
| `unified-observed` | 32 | 1.72 GB | 1.6 min | 5,130,137 rows; identical |

That is about 1 GB instead of 11.7 GB for an active-layer spec. Compiling
from the downloaded database took 11.2 min in the 2026-10-26 remote check.

The download is larger than the 0.7 GB I first estimated. A spec needs every
name class of its layers (observed names alone are 0.13 GB for `bmf_active`),
plus the statistics and cluster tables (0.12 GB).

**Lookups:** `md_lookup()` (every part, including `orgtext`) and
`md_cluster()` on a connection holding all the tranches are identical to the
database for three EINs. They take about 1 s each, compared with 0.4–0.9 s on
the database.

## Publishing to S3

The remote layout mirrors the local one under the matchdb remote:
`tranches/<build>/...` and `tranches/latest.json`. Upload the build directory
first and `latest.json` last, so a reader never finds a pointer to a partial
build:

```bash
aws s3 sync "$MATCHDB_DATA/tranches/<build>" s3://nccs-efile/dev/matchdb/tranches/<build> --only-show-errors
aws s3 cp "$MATCHDB_DATA/tranches/latest.json" s3://nccs-efile/dev/matchdb/tranches/latest.json
```

`md_fetch_tranches()` reads over plain HTTPS, so like the database and the
bundles, no AWS account is needed.

**Uploaded 2026-10-27:** build `2026-10-27-82c6f0cb`, 109 objects, 4.64 GB,
7 min. Every file's md5 was checked before upload; the manifest went after the
files, and `latest.json` last.

**Fetched back over public HTTPS** (`dev/verify/tranche-remote.R`, log in
`dev/verify/logs/tranche-remote-2026-10-27.log`), from `md_remote()` with no
credentials:

| step | download | result |
|---|---:|---|
| `active-observed` | 1.18 GB, 1.0 min | compiled in 1.3 min; identical to the bundle |
| then `unified-observed` | 0.54 GB, 0.5 min (the 19 files it shares were skipped) | compiled in 2.1 min; identical to the bundle |
| then `tables = "all"` | 2.92 GB, 2.8 min | `md_lookup()` and `md_cluster()` identical to the database |

## Not done

* **Reading parquet straight off S3 without downloading** works in DuckDB
  (`read_parquet('https://…')`) and would suit single-EIN lookups. It is not
  wired up, and compiling should download first anyway (§7a).
* **Rebuilding the same database gives a new build id.** Whole tables are
  sorted by EIN only, so rows that tie on EIN can come out in a different
  order and the files' bytes (and md5s) change. The two 2026-10-27 runs gave
  `9e7ae7a9` and `82c6f0cb`, with identical contents. A full sort would make
  the id a pure function of the data, at some cost on the big tables.
* **Per-cell posting lists** (§6c, §7g) would make `ref_index` a sum as well.
  It is still built from the frame.
