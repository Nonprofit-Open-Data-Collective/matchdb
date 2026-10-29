# The observation ledger

Phase 5 step 4 (`dev/IDENTITY.md` §4, §5). Every observation of a name
or address, from every release of every source, is one row of `obs`.
Rows are never deleted: a row a later release no longer carries is
marked `retracted_in`, and a snapshot value that stops appearing simply
stops being extended.

## Usage

``` r
md_ledger_schema(con)
```

## Arguments

- con:

  A DuckDB connection.

## Value

`md_ledger_schema()`: `con`, invisibly.

## Details


    obs_id           content-hash id (below)
    source, kind     as in md_sources()
    part             the partition (tax year) the row came from, or NULL
    ein              EIN2
    role             legal | dba | in_care_of | observed | mailing | historical | ...
    name_text_id     NULL for an address-only record
    address_text_id  NULL for a name-only record
    asserted_by      the filer who wrote it, for third-party sources
    record_key       the source's natural key (md_record_keys())
    trace_key        a publisher's row id (e-file TABLE_ID), for tracing only
    period           the year the row describes, if it has one
    filed_at         the return's timestamp, so the latest return can be chosen
    first_seen, last_seen  release vintages, or the range the source states
    bounds_kind      spell | period | stated | envelope
    first_release, last_release  release_ids
    retracted_in     release_id that dropped this row, else NULL

## Ids

- Snapshot:

  `md5('obs.v1', source, ein, role, name_text_id, address_text_id, first_seen)`:
  one id per spell, so a value that comes back after a change opens a
  new spell.

- Every other kind:

  `md5('obs.v1', source, record_key, row_hash, occurrence)`, where
  `row_hash = md5('row.v1', ein, role, name_text_id, address_text_id, asserted_by, period)`
  and `occurrence` numbers rows identical in all of those within one
  record. A corrected value in a re-released filing is therefore a new
  row, and the old one is retracted, rather than an update the diff
  cannot see.
