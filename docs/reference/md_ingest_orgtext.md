# Ingest mission and program text

Fills `orgtext`, the last empty core table: one row per
`(ein, tax_year, text_kind)` carrying what an organisation wrote about
what it does.

## Usage

``` r
md_ingest_orgtext(version = "v2_2", con = NULL, kinds = NULL)
```

## Arguments

- version:

  Pinned `efile_orgtext` version.

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- kinds:

  Which text kinds to load. Defaults to all present.

## Value

Row counts by kind, invisibly.

## It is adjudication input, not candidate generation

Section 10 is explicit that this stays outside the name and address
selection machinery. `pf_purpose_tiebreak()` consumes mission text
*after* a candidate list exists, to choose between candidates that
already look plausible. It is not a blocking key and must not become
one - at four million EINs and paragraph-length strings, blocking on it
would be a disaster.

So `orgtext` is deliberately EIN-keyed and joined on demand. It carries
no `variant_class`, appears in no spec axis, and nothing in
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
will ever select on it.

## Why it is a panel and the other tables are not

`name` and `address` collapse repeated observations into one row per
distinct value, because a spelling written twice is not two spellings.
Text is different: an organisation rewrites its mission, and the rewrite
is a fact about that year rather than a duplicate to be merged. Rows are
therefore kept per `(ein, tax_year, text_kind)`, and identical text
repeated across years is preserved rather than deduplicated.

## Text is stored as filed

No case folding, no punctuation stripping, no truncation. The normalised
forms that `name` carries exist because names are *matched on*; mission
text is read, quoted and shown to an adjudicator, so mangling it would
destroy the thing that makes it useful. Any normalisation a consumer
wants is a consumer's decision.
