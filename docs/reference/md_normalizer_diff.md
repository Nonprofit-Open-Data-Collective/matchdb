# What a new normalizer would change

Phase 5 step 7 (`dev/IDENTITY.md` §7). Derived columns are stored per
string and per normalizer signature
([`md_build_text_derived()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_text.md)),
so after installing a new npmatch the old signature's rows are still
there beside the new one's. This compares the two before the new one is
adopted:

## Usage

``` r
md_normalizer_diff(
  con,
  old,
  new = npnormalize::np_normalize_signature(),
  examples = 5L
)
```

## Arguments

- con:

  A DuckDB connection.

- old, new:

  The two normalizer signatures. `new` defaults to the installed
  npmatch's.

- examples:

  Changed strings to show per column.

## Value

An object of class `md_normalizer_diff`: a list of the four data frames
above, plus `old` and `new`.

## Details

- `coverage`:

  Strings with a row under each signature, and under both.

- `columns`:

  For every derived column, how many strings got a different value.

- `examples`:

  Up to `examples` changed strings per column, with the old and new
  value.

- `groups`:

  What that does to the rows of `name` and `address`: per EIN, groups
  that merge (rows with different old keys now share one) and groups
  that split (rows sharing an old key now differ), on `name_key` for
  names and on `street_key` plus ZIP for addresses, and how many EINs
  either touches. These are the rows whose compact group, and so whose
  compiled reference row, would change.

Workflow: with the old npmatch installed,
[`md_build_text_derived()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_text.md)
has stored the old signature. Install the new npmatch and run
[`md_build_text_derived()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_text.md)
again, which adds the new signature beside it. Then run this. Adopt the
new signature by rebuilding with it; drop the old rows only when no
published tier still names it.
