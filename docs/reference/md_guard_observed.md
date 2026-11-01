<div id="main" class="col-md-9" role="main">

# Guards on observed names: is the written name really this EIN's?

<div class="ref-description section level2">

Schedule I and Schedule R give a *(name, EIN)* pair written by a third
party. Both halves can be wrong, and wrong in systematic ways that
corroboration does not screen out, because the same habit repeats across
filers. networked990's resolver checks every written EIN against its
names (`R/resolve.R` v1.4-v1.6) and in one rebuild dropped 18,326 own or
group-central EINs, found 39,016 written EINs whose names share no word
with the mention, and 2,879 EINs written for many unrelated names
(fiscal sponsors). Loaded unchecked, every one of those becomes an alias
here.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_guard_observed(
  con,
  sources = NULL,
  common_min_eins = 2000L,
  sponsor_min_names = 5L,
  sponsor_min_filers = 2L
)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A connection from `md_db()`.

-   sources:

    `name.source` values to check. `NULL` checks every `observed` row.

-   common_min_eins:

    A word on more than this many EINs' first-party names is too common
    to show two names are the same organisation.

-   sponsor_min_names, sponsor_min_filers:

    Fiscal-sponsor thresholds.

</div>

<div class="section level2">

## Value

Per-flag row counts by source, invisibly.

</div>

<div class="section level2">

## Details

`md_guard_observed()` flags `observed` rows rather than dropping them,
so the raw observation keeps its provenance and the choice stays with
the spec.

</div>

<div class="section level2">

## Columns written on `name`

-   `flag_placeholder_ein`:

    EIN is a placeholder: nine repeated digits, `123456789`,
    `987654321`, or a value below 1,000,000 (`EIN-00-0xxxxxx`; the
    ingests zero-pad, so a written `0` lands here).

-   `flag_placeholder_name`:

    Name is no name by npmatch's rule,
    `npnormalize::np_name_placeholder()`: `SEE SCHEDULE O`,
    `SEE ATTACHED`, `VARIOUS`, `N/A`, `NONE`, `SAME AS ABOVE`, blank, or
    no letters - unless it is consistent with the EIN's own names (`SEE`
    for Social and Environmental Entrepreneurs).

-   `flag_own_ein`:

    The only filers who wrote this name for this EIN were the EIN
    itself, and the name is not consistent with that EIN's names (a
    grantee or related organisation listed under the filer's EIN). A
    name other filers also wrote for the EIN is not flagged: on Schedule
    R that is an affiliate listing itself under a name its siblings use
    too.

-   `flag_group_central`:

    EIN is a group-ruling central (BMF affiliation code 6 or 8) and the
    name shares no word with the central's names other than denomination
    words (a congregation written under the PC(USA) EIN).

-   `flag_multi_name`:

    EIN was written on others' Schedule I for `sponsor_min_names`+ names
    inconsistent with its own, by `sponsor_min_filers`+ filers, and this
    row is one of those names (a project under Tides Center or Fractured
    Atlas). The EIN's consistent names keep no flag.
    `entity.multi_name_ein` marks the EIN itself. Not only fiscal
    sponsors meet this: universities (departments, centres),
    denominational centrals and national federations do too, and their
    rows are flagged alike - a name unlike the EIN's own is not an alias
    of it either way. Applies to Schedule R rows on the same EIN as
    well.

-   `name_ein_consistent`:

    The name shares a distinctive word (3+ characters, on no more than
    `common_min_eins` EINs' names) or any two words of 3+ characters
    with one of the EIN's first-party names, equals one (spaces
    ignored), or is its acronym, long prefix or abbreviation.
    Apostrophes are dropped before keying (`ST MARY'S` = `ST MARYS`).
    `NA` when the EIN has no first-party name to compare against. Not a
    guard by itself: it also fails for real brand names, and for
    subordinates whose BMF name is the parent's.

-   `guard_any`:

    Any of the five `flag_*` columns. The spec filter that matches
    networked990's resolver is `NOT guard_any`.

First-party names are `legal`, `dba`, `division` and `former` rows from
any source (BMF, return headers, 1023-EZ). Re-run this after every
ingest that adds them: flags computed before the return headers load see
fewer names.

The name key, abbreviations, stop words and placeholder rule are
npmatch's (`npnormalize::np_name_rules()`). `DENOM_WORDS` and the
abbreviation-match rules (`md_name_pair_hit()`) are copied from
networked990 `R/names.R` (2026-10-21).

</div>

</div>
