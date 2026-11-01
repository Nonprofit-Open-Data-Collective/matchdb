<div id="main" class="col-md-9" role="main">

# Everything the database knows about an EIN

<div class="ref-description section level2">

`md_lookup()` gathers, for one or more EINs, the rows every table holds:
the entity record, every observed name and address with its source,
dated events (990-N terminations, revocations), relations disclosed in
either direction, cluster memberships, shared identifiers and websites.
It is the read side of the database for a person, not for a matcher; to
build a reference for matching use `md_spec()` and `md_compile()`.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_lookup(ein, parts = md_lookup_parts(), include_people = FALSE, con = NULL)

md_lookup_parts()
```

</div>

</div>

<div class="section level2">

## Arguments

-   ein:

    One or more EINs, in any form `md_ein()` accepts.

-   parts:

    Which parts to return. The default is every part except `"orgtext"`.

-   include_people:

    Include officer name keys among the shared keys.

-   con:

    A connection from `md_db()`; opened read-only and closed when
    `NULL`.

</div>

<div class="section level2">

## Value

An `md_lookup`: a named list of data frames, one per part, each with an
`ein` column. Parts whose table is not in the database are absent.

</div>

<div class="section level2">

## What is left out by default

Part VII officer keys (`ein_key` rows of kind `person`) are derived from
people's names. They are left out unless `include_people = TRUE`.
Mission and program text is large and is left out unless `"orgtext"` is
in `parts`.

</div>

<div class="section level2">

## Examples

<div class="sourceCode">

``` r
if (FALSE) { # \dontrun{
x <- md_lookup("53-0196605")
x
x$names
} # }
```

</div>

</div>

</div>
