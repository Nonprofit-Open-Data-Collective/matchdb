<div id="main" class="col-md-9" role="main">

# Text dictionaries and derived columns keyed on the text

<div class="ref-description section level2">

Phase 5 step 3 (`dev/IDENTITY.md` §4, §7). Every distinct name string
and every distinct address, as written, is stored once under its
content-hash id (`md_name_text_id()`, `md_address_text_id()`), and the
normalizer's output is stored against that id and the normalizer
signature:

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_text_schema(con)

md_add_text(con, relation, what = c("name", "address"))

md_build_text(con)

md_build_text_derived(con, what = c("name", "address"), chunk = 1000000L)

md_check_text_derived(
  con,
  signature = npnormalize::np_normalize_signature(),
  stop_on_missing = FALSE
)

md_text_stats(con)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A DuckDB connection, usually from `md_db()`.

-   relation:

    A table, view or query (in parentheses) holding raw text. Names: a
    `name_raw` column. Addresses: `street_raw`, `city_raw`, `state`,
    `zip5`, `zip_plus4`, and optionally `unit_raw`.

-   what:

    `"name"` or `"address"`.

-   chunk:

    Strings per normalizer pass. Bounds memory, not correctness.

-   signature:

    The normalizer signature to check against. Defaults to the installed
    npmatch's.

-   stop_on_missing:

    Error, rather than return, when a string has no row for the
    signature.

</div>

<div class="section level2">

## Value

`md_text_schema()`: `con`, invisibly.

`md_add_text()`: the number of new strings, invisibly. Existing ids are
left alone, so adding the same text twice adds nothing.

`md_build_text()`: new strings per table, invisibly.

`md_build_text_derived()`: strings normalized per table, invisibly.

`md_check_text_derived()`: a data frame per table of strings, strings
with a row for the signature, and strings missing one.

`md_text_stats()`: the step 3 measurement - rows in `name` and `address`
against distinct strings in the dictionaries, and the derived rows per
signature.

</div>

<div class="section level2">

## Details

-   `release`:

    One row per file or partition read. Filled by the ingest engine
    (step 4); created here so the schema is complete.

-   `name_text`:

    `name_text_id`, `name_raw` (canonical form).

-   `address_text`:

    `address_text_id`, `street_raw`, `unit_raw`, `city_raw`, `state`,
    `zip5`, `zip_plus4`.

-   `name_text_derived`:

    Primary key `(name_text_id, normalize_signature)`: the same columns
    `md_build_derived()` stores in `name_derived`.

-   `address_text_derived`:

    Primary key `(address_text_id, normalize_signature)`: the columns of
    `address_derived`.

What this changes against `name_derived`/`address_derived`, which key on
row ids:

-   A text id never changes, so a re-ingest cannot orphan a derived row.

-   Only strings never seen before are normalized. A string shared by
    thousands of EINs is normalized once.

-   Two normalizer signatures can sit side by side, so adopting a new
    npmatch never overwrites the columns a published tier was built on.

Until the ingest engine exists (step 4), `md_build_text()` fills the
dictionaries from the current `name` and `address` tables, so the sizes
and timings the plan asks for can be measured on a built database.

</div>

</div>
