# Build the derived-column tables

Runs
[`npnormalize::np_normalize()`](https://nonprofit-open-data-collective.github.io/npnormalize/reference/np_normalize.html)
over `name` and `address` and stores the output as `name_derived` and
`address_derived`, keyed on `name_id` / `address_id`.

## Usage

``` r
md_build_derived(
  con = NULL,
  what = c("name", "address"),
  chunk = 1000000L,
  incremental = FALSE
)
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- what:

  Which tables to build.

- chunk:

  Rows per pass. Bounds peak memory, not correctness.

- incremental:

  Derive only rows that have no derived row yet, and delete derived rows
  whose source row is gone. For adding a source to a built database;
  refused if the stored rows were built by another normalizer.

## Value

Row counts, invisibly.

## Why separate tables rather than columns

§9 says the normalizer will drift, and it already has once. When it
does, the derived values are stale and the base rows are not. Separate
tables make that a `DROP` and a rebuild rather than an `ALTER` rewriting
18.5M rows in tables that are meant to be append-only, and they let the
signature be checked per table: a mismatch says exactly which artifact
to rebuild.

## Why it costs what it costs

`np_normalize()` computes all 19 derived columns regardless of input, so
the name pass also parses streets over stub columns and the address pass
parses names it will not keep. Measured at 18.1 s and 14.0 s per 200,000
rows, which is roughly 36 minutes for both tables and about half of that
wasted. The waste is accepted deliberately: calling the exported
function is what makes `np_normalize_signature()` a true statement about
how these columns were produced. Calling internals would be faster and
would make the stamp a lie.
