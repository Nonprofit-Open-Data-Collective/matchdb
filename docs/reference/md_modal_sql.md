# Deterministically pick a representative value

Generates SQL that chooses, per group, the most frequently occurring
value of a column, breaking ties by sorting the value itself. Used
wherever an ingest collapses many source rows into one and has to keep a
single spelling.

## Usage

``` r
md_modal_sql(table, by, value, where = NULL, alias = NULL)
```

## Arguments

- table:

  Source table or CTE name.

- by:

  Character vector of grouping columns.

- value:

  Column whose representative value is wanted.

- where:

  Optional SQL predicate applied before counting.

- alias:

  Name for the generated CTE.

## Value

A single SQL string defining the CTE.

## Why not mode()

DuckDB's [`mode()`](https://rdrr.io/r/base/mode.html) returns *an*
most-common value, not *the* most-common one. Under a tie it picks
arbitrarily, and arbitrarily is not deterministically - the choice can
differ between runs over byte-identical input.

That is not cosmetic. In the Schedule I ingest it changed the row count:
a tie between `''` and a real street name flipped which side of a
non-empty filter the row landed on, and two consecutive runs produced
address counts differing by one. Section 7c makes determinism a hard
requirement - "the spec hash is worthless if the same spec can yield
different rows" - so a build that cannot reproduce its own row count
cannot be published against a hash at all.

The same objection applies to every "give me a representative"
aggregate: [`mode()`](https://rdrr.io/r/base/mode.html), `any_value()`,
`first()`, `arg_max()` and `arg_min()` are all arbitrary under ties.
**None of them should appear in an ingest.** This function exists so
that the correct construction is shorter to write than the incorrect
one.

## What it generates

A `row_number()` window partitioned by the grouping columns and ordered
by descending frequency then ascending value, filtered to rank 1.
Frequency decides; the value's own sort order settles ties. Both halves
are total orders over the input, so the result is a pure function of the
data.

Alphabetical is an arbitrary tiebreak in the sense that no spelling is
more correct than another - but it is a *fixed* arbitrary, which is the
property that matters. Prefer it over anything data-dependent like
"longest" or "most recent", which reintroduce ties of their own.

## Examples

``` r
cat(md_modal_sql("si_clean", c("ein", "name_key"), "name_raw"))
#> modal_name_raw AS (
#>       SELECT ein, name_key, name_raw,
#>              row_number() OVER (PARTITION BY ein, name_key
#>                                 ORDER BY count(*) DESC, name_raw ASC) AS rk
#>       FROM si_clean
#>       GROUP BY ein, name_key, name_raw
#>     )
```
