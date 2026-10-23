# Everything the database knows about an EIN

`md_lookup()` gathers, for one or more EINs, the rows every table holds:
the entity record, every observed name and address with its source,
dated events (990-N terminations, revocations), relations disclosed in
either direction, cluster memberships, shared identifiers and websites.
It is the read side of the database for a person, not for a matcher; to
build a reference for matching use
[`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md)
and
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md).

## Usage

``` r
md_lookup(ein, parts = md_lookup_parts(), include_people = FALSE, con = NULL)

md_lookup_parts()
```

## Arguments

- ein:

  One or more EINs, in any form
  [`md_ein()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ein.md)
  accepts.

- parts:

  Which parts to return. The default is every part except `"orgtext"`.

- include_people:

  Include officer name keys among the shared keys.

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md);
  opened read-only and closed when `NULL`.

## Value

An `md_lookup`: a named list of data frames, one per part, each with an
`ein` column. Parts whose table is not in the database are absent.

## What is left out by default

Part VII officer keys (`ein_key` rows of kind `person`) are derived from
people's names. They are left out unless `include_people = TRUE`.
Mission and program text is large and is left out unless `"orgtext"` is
in `parts`.

## Examples

``` r
if (FALSE) { # \dontrun{
x <- md_lookup("53-0196605")
x
x$names
} # }
```
