# Ingest the unified BMF into entity, name and address

Reads the pinned BMF parquet and writes the three core tables.
Idempotent: a full load keyed on `source_vintage`, per §10, so
re-running replaces rather than accumulating.

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

A named list of row counts, invisibly.

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
