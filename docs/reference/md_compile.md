# Compile a spec into the reference frame npmatch matches against

Turns an
[`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md)
into the wide `np_reference` frame: one row per EIN x selected name x
paired address, with npmatch's derived columns, `.ein`, `.id` and
`active` (`PLAN.md` section 6). It also returns the corpus statistics
for exactly that selection, and a report of what the selection emits and
what it leaves out.

## Usage

``` r
md_compile(
  spec,
  con = NULL,
  derive = c("stored", "normalize", "none"),
  max_rows = 2e+07,
  check_rows = 2000L
)
```

## Arguments

- spec:

  An
  [`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md).

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- derive:

  `"stored"` (the npmatch frame from stored columns), `"normalize"` (the
  same frame, by running `np_normalize()`) or `"none"` (raw fields
  only).

- max_rows:

  Row budget. Emission is counted before anything is materialised, and a
  spec over budget is an error naming the classes responsible, rather
  than a reference that costs far more than planned.

- check_rows:

  For `derive = "stored"`, how many rows to re-normalize and compare. 0
  skips the check.

## Value

An object of class `md_reference`: `reference` (the frame), `name_freq`,
`token_idf`, `name_eins`, `token_df`, `n_name_rows`, `report`, `spec`
and `stamp`.

## Where the rows come from

Names come from `name_compact`: one row per `(ein, name_key)`, collapsed
across sources, without in-care-of names or guarded observed rows.
Addresses come from `address` and `address_derived`, collapsed here over
the selected classes to one row per place - `address_compact` has no
variant class to select on.

## The pairing rule

Section 8: a third party wrote an observed name *together with* an
address, so an `observed` name pairs with the observed addresses written
beside it (`address.name_id`), and only first-party names cross with
first-party addresses. Emission is then roughly names + addresses per
EIN, not their product. An observed name with no address of its own
pairs with the EIN's first-party addresses; an EIN with no selected
address still gets one row per name, with the address fields empty.

## Derived columns

Every column
[`npmatch::np_normalize()`](https://nonprofit-open-data-collective.github.io/npmatch/reference/np_normalize.html)
adds is a function of one input field, and
[`md_build_derived()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_build_derived.md)
stores all of them. `derive = "stored"` (the default) gives each row the
stored columns of a row holding exactly its strings - the name row with
its spelling, the address row with its street, zip and state, the DBA
row with its DBA - so the frame is what `np_normalize()` would build,
without running it. A sample of `check_rows` rows is then re-normalized
and compared, and any difference is an error. `derive = "normalize"`
runs `np_normalize()` on the whole frame instead.

Either way the installed normalizer must be the one that built
`name_derived`, because `name_compact`'s keys came from it.

## Statistics

Two kinds, both returned:

- `name_freq`, `token_idf`:

  npmatch's own, over the emitted frame - what
  [`npmatch::np_cascade()`](https://nonprofit-open-data-collective.github.io/npmatch/reference/np_cascade.html)
  uses today. A name repeated once per paired address counts once per
  row.

- `name_eins`, `token_df`, `n_name_rows`:

  over names, one per `(ein, name_key)`. For a spec without a
  cross-cutting filter these are summed from
  [`md_build_stats()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_build_stats.md)'s
  cells; otherwise computed directly from the selected names.
  `report$stats_method` says which.

## The report

Shape: rows by name and address class, rows per EIN, EINs with no
address. Absence (section 8a): for each cluster type, how many selected
EINs have a family member the selection leaves out. A thin reference
cannot see the sibling it is missing, and auto-accepts against whichever
member it holds; this is the count that says how often that can happen.
