# Record an ingest in the audit table

Writes one `source_vintage` row per load, carrying the pin (§4). Nothing
else makes a compiled reference explainable six months later.

## Usage

``` r
md_record_vintage(
  con,
  source,
  version,
  table_name,
  row_count,
  build_note = "",
  content_vintage = NULL,
  content_vintage_rule = NULL
)
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- source, version:

  The pinned source.

- table_name, row_count:

  What was written.

- build_note:

  Free text.

- content_vintage:

  What period the loaded data describes (e.g. `"2026-07"` for a BMF
  release whose newest internal vintage differs from its publish date),
  as distinct from `fetched` (when we downloaded it) and
  `upstream_modified` (when the file was published). `NULL` falls back
  to `upstream_modified` under `content_vintage_rule = "published"` — a
  weaker claim, recorded as such rather than presented as equivalent to
  a measured value. See `PLAN.md` section 4.

- content_vintage_rule:

  How `content_vintage` was obtained: `"measured"` (read from the data
  itself), `"declared"` (supplied by the caller because nothing in the
  data says it), or `"published"` (fell back to `upstream_modified`).
  Inferred as `"declared"` when `content_vintage` is supplied without an
  explicit rule, `"published"` when it falls back, and `NA` when neither
  is available.
