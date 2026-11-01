<div id="main" class="col-md-9" role="main">

# Intrinsic validation of a built table

<div class="ref-description section level2">

The gate for every ingest phase. These are properties the database is
checked against *on its own terms* - key uniqueness, EIN wellformedness,
referential integrity, provenance completeness, and agreement between
the stored derived columns and a live `npnormalize::np_normalize()`
call.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_validate(
  x,
  key = NULL,
  ein = "ein",
  parent = NULL,
  enums = list(),
  required = character(),
  sample = 1000L
)

md_validate_report(v, stop_on_fail = TRUE)
```

</div>

</div>

<div class="section level2">

## Arguments

-   x:

    A `data.frame`/`data.table` to check.

-   key:

    Column(s) forming the primary key. Checked for uniqueness and
    completeness.

-   ein:

    Name of the EIN column, or `NULL` to skip the EIN checks.

-   parent:

    Optional vector of valid EINs (typically `entity$ein`) for a
    referential-integrity check.

-   enums:

    Named list of allowed values, e.g.
    `list(variant_class = c("legal", "dba"))`.

-   required:

    Columns that must be present and wholly non-missing. Provenance
    columns belong here.

-   sample:

    Rows to draw for the derived-column agreement check. `0` skips it.

-   v:

    Output of `md_validate()`.

-   stop_on_fail:

    Error rather than return when any check fails. Phase gates use
    `TRUE`; interactive inspection uses `FALSE`.

</div>

<div class="section level2">

## Value

A `data.frame` with one row per check: `check`, `pass`, `n_bad`,
`detail`.

</div>

<div class="section level2">

## Details

It is deliberately not a comparison against a previously built artifact.
matchdb is built from the freshest available sources, so "matches the
file we had before" is not a property worth having: it would pin the
database to an older vintage and to a build nobody can reproduce.
Attribution against the existing pfmatch reference belongs at cutover,
where it is a question about two references rather than a constraint on
this one.

</div>

</div>
