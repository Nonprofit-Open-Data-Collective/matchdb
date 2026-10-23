# Ingest Form 1023-EZ approvals

The 1023-EZ is the streamlined application for recognition of exemption.
Its approval extracts give, per approved organisation, the **name and
address as the organisation itself wrote them at application**, and an
NTEE code the organisation selected.

## Usage

``` r
md_ingest_f1023ez(
  version = "v2014-2023",
  con = NULL,
  new_entity_layer = "approved_only",
  reconvert = FALSE
)
```

## Arguments

- version:

  Pinned version directory, e.g. `"v2014-2023"`.

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- new_entity_layer:

  Layer under which to admit approved organisations that appear in no
  BMF release. `NULL`, the default, holds them back instead. No value in
  the frozen enumeration (section 3a) describes an organisation the IRS
  granted exemption to but which reached no BMF release: `filer_only`
  means observed on a 990-series filing, and an approval is not a
  filing. Set this once that question is settled.

- reconvert:

  Redo the xlsx-to-CSV step even if a CSV is already present.

## Value

Row counts, invisibly.

## Why this source earns its place

Every other NTEE input here traces to the same assignment. The
crosswalk's `ntee_current` agrees with the BMF 99.96% of the time - it
is the same value, not a second opinion
([`?md_ingest_ntee`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_ntee.md)).
The 1023-EZ code is genuinely independent: the organisation chose it,
before any IRS or NCCS processing touched it. That makes it the only
available cross-check on a classification the rest of the database takes
on trust.

The name is independent in the same way. A 1023-EZ name is what the
founders filed under, which may differ from the BMF legal name recorded
later, and those differences are exactly the variants a matcher needs.

## Personal data is not ingested

Columns 18-57 of the source are five officers' names and **home
addresses**. They are never parsed -
[`md_xlsx_to_csv()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_xlsx_to_csv.md)
takes a column list, so unwanted columns are not read rather than read
and dropped. matchdb is a database of organisations.
