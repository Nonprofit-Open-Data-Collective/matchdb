<div id="main" class="col-md-9" role="main">

# How corroboration is counted and recorded

`vignette("corroborators")` explains what `n_corroborators` means and
how to choose a threshold. This vignette explains how the count is made:

-   where each filer’s statement is stored;
-   how the statements become one row in `name`;
-   how the guards read the same rows;
-   what happens to the count when a new release arrives.

The figures are from the build of 2026-11-01 (`matchdb@df7e2ce`,
normalizer `v1-592912060053c4c3`).

<div class="section level2">

## Who says what

Most of what matchdb holds is **first-party**: the IRS or the
organization itself, in the BMF, a 990 header, a 1023-EZ, an e-Postcard.
A first-party name is corroborated by time. A name an organization files
under for ten years has `n_periods = 10`.

An **observed** name is written by a third party, next to the EIN it is
about. Three sources do this. Each is a `mentions` source
(`md_source_kinds()`): one filer can write about an EIN as often as it
likes, and every time is kept.

| source                    | where                                                          | observations | filers | EINs written about |
|---------------------------|----------------------------------------------------------------|-------------:|-------:|-------------------:|
| `schedi`                  | Schedule I Part II: a grantmaker’s US grantees                 |    8,798,053 | 93,953 |            823,481 |
| `efile_related`           | Schedule R Part II: related exempt organizations               |    6,389,480 | 94,071 |            121,853 |
| `efile_affiliate_listing` | the group-return roster: a central organization’s subordinates |       28,850 |    341 |              7,845 |

Each observation records **who wrote it**: the filer’s EIN, as
`asserted_by`. That one column is what corroboration counts.

</div>

<div class="section level2">

## The ledger

Every observation from every source is one row in the **observation
ledger**. Rows are never deleted or overwritten. Three tables hold it:

| table                       | one row per                                                                       | what it holds                                                                                                                                                        |
|-----------------------------|-----------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `release`                   | file read: a source, a version and a part, which is a tax year for e-file sources | `file_md5`, `n_rows`, `seq` (the order of application), `ingested_at`                                                                                                |
| `obs`                       | observation                                                                       | `ein`, `role`, `name_text_id`, `address_text_id`, `asserted_by`, `period` (the tax year), `record_key` (the return), `first_release`, `last_release`, `retracted_in` |
| `name_text`, `address_text` | distinct string                                                                   | the string as written, keyed by a content hash                                                                                                                       |

The ledger holds 48.3M observations from 82 releases. Schedule I alone
is 17 releases, one for each tax year from 2009 to 2025.

**The ledger is in the maintainer copy only.** `MATCHDB-full.duckdb`
(24.2 GB) has it. `MATCHDB.duckdb` (11.8 GB), which `md_fetch_db()`
downloads, keeps the rollups built from it, described below. To read the
ledger, download the full copy from the same location (`md_remote()`).

One observation holds a name and an address together when the filer
wrote them together. Here is every Schedule I statement about one EIN,
Habitat for Humanity of Greater Boston, as the ledger has them (first
rows):

<div id="cb1" class="sourceCode">

``` r
con <- md_db(read_only = TRUE, path = "MATCHDB-full.duckdb")
DBI::dbGetQuery(con, "
  SELECT o.asserted_by, o.period, t.name_raw, o.record_key
  FROM obs o JOIN name_text t USING (name_text_id)
  WHERE o.ein = 'EIN-04-2994233' AND o.role = 'observed'
  ORDER BY t.name_raw, o.asserted_by, o.period")
#>      asserted_by period                    name_raw             record_key
#>   EIN-91-1914868   2016       Bangor HFH of Greater OID-201713259349300911
#>   EIN-91-1914868   2016         Bennington Area HFH OID-201713259349300911
#>   EIN-68-0480736   2010 Boston Habitat for Humanity OID-201121809349300617
#>   EIN-68-0480736   2011 Boston Habitat for Humanity OID-201221819349300232
#>   EIN-91-1914868   2009      GREATER BOSTON INC HFH OID-201140539349300109
#>   EIN-91-1914868   2011      GREATER BOSTON INC HFH OID-201203569349300870
#>   ...
#>   EIN-91-1914868   2020      GREATER BOSTON INC HFH OID-202143379349300209
#>   EIN-91-1914868   2020      GREATER BOSTON INC HFH OID-202133199349308053
#>   ...
```

</div>

`record_key` is the return the statement came from, so any count below
can be traced back to the filings behind it.

</div>

<div class="section level2">

## From statements to a name row

`name` is rebuilt from the ledger on every build; it is never edited in
place. Statements are grouped by EIN, source and class, and by the
name’s **light key** (`md_light_key()`: uppercased, accents and `&`
spelled out, punctuation dropped). So `Boston Habitat for Humanity` and
`BOSTON HABITAT FOR HUMANITY` are one group. Each group becomes one row:

| column                                          | how it is counted                                                                               |
|-------------------------------------------------|-------------------------------------------------------------------------------------------------|
| `n_corroborators`                               | distinct `asserted_by`: how many different filers wrote it                                      |
| `n_mentions`                                    | statements, counting each filer’s latest return for a tax year once                             |
| `n_periods`                                     | distinct tax years it was written in                                                            |
| `first_year`, `last_year`                       | the first and last of those years                                                               |
| `name_raw`                                      | the group’s most frequent spelling, ties broken alphabetically, so a rebuild picks the same one |
| `n_self_filers`, `filer_ein_lo`, `filer_ein_hi` | how many filers wrote their own EIN, and the range of the others; the guards read these         |

The same EIN’s rows in `name`:

<div id="cb2" class="sourceCode">

``` r
DBI::dbGetQuery(con, "
  SELECT name_raw, source, n_corroborators, n_mentions, n_periods, first_year, last_year
  FROM name WHERE ein = 'EIN-04-2994233'
  ORDER BY variant_class, n_corroborators DESC NULLS LAST")
#>                                  name_raw   source n_corroborators n_mentions n_periods first_year last_year
#>                    HFH GREATER BOSTON INC      bmf              NA          0         0         NA        NA
#>   HABITAT FOR HUMANITY GREATER BOSTON INC efile990              NA          0        16       2009      2024
#>       HABITAT FOR HUMANITY GREATER BOSTON   schedi              10         17         9       2012      2024
#>   HABITAT FOR HUMANITY GREATER BOSTON INC   schedi               9         34        13       2012      2025
#>    HABITAT FOR HUMANITY INTERNATIONAL INC   schedi               5         25        11       2014      2024
#>                      HABITAT FOR HUMANITY   schedi               2          3         3       2021      2024
#>                    GREATER BOSTON INC HFH   schedi               1          9         9       2009      2024
#>                       Bennington Area HFH   schedi               1          1         1       2016      2016
#>   ...
```

</div>

Three things to read in it:

-   **Repetition by one filer is not corroboration.**
    `GREATER BOSTON INC HFH` was written in nine years, every time by
    the same filer (`EIN-91-1914868`): 9 mentions, 1 corroborator. That
    filer sent two 2020 returns, and only the later one counts.
-   **Agreement across filers is.** Ten different grantmakers wrote
    `HABITAT FOR HUMANITY GREATER BOSTON`. That is the name a grant
    record is likely to carry, and the BMF’s `HFH GREATER BOSTON INC` is
    not.
-   **A single filer can simply be wrong.** The filer that wrote
    `GREATER BOSTON INC HFH` also wrote `Bennington Area HFH` and
    `Bangor HFH of Greater` under this EIN, in the same 2016 return.
    Those are other affiliates, given the wrong EIN.
    `min_corroborators = 2` leaves them out without anyone having to
    find them.

The BMF row has `n_corroborators = NA`, not 0. First-party rows have no
`asserted_by`, so the count does not apply to them.

</div>

<div class="section level2">

## Addresses travel with their names

A grantmaker writes a name and an address together, and the rollup keeps
the pair. Each observed address row carries the `name_id` of the name it
was written with:

<div id="cb3" class="sourceCode">

``` r
DBI::dbGetQuery(con, "
  SELECT a.street_raw, a.city_raw, a.zip5, a.n_corroborators, n.name_raw AS written_with
  FROM address a LEFT JOIN name n ON n.name_id = a.name_id
  WHERE a.ein = 'EIN-04-2994233' AND a.variant_class = 'observed'
  ORDER BY a.n_corroborators DESC")
#>                         street_raw city_raw  zip5 n_corroborators                            written_with
#>    240 Commercial Street 4th Floor   Boston 02109               7 HABITAT FOR HUMANITY GREATER BOSTON INC
#>    240 COMMERCIAL STREET 4TH FLOOR   BOSTON 02109               6     HABITAT FOR HUMANITY GREATER BOSTON
#> 434 MASSACHUSETTS AVENUE SUITE 201   BOSTON 02118               5     HABITAT FOR HUMANITY GREATER BOSTON
#>   ...
```

</div>

An observed address is counted the same way: distinct filers who wrote
that place with that name. It is grouped on the name, city, state and
ZIP, keeping the commonest street spelling. Grouping on the street as
well would have split one grantee’s place into a row per spelling. A
compiled reference therefore pairs each alias with its own addresses,
about *k + m* rows for an EIN with *k* names and *m* addresses, not *k ×
m*.

</div>

<div class="section level2">

## What the guards add

Corroboration asks how many filers agree. Some errors are habits, and
habits repeat across filers. `md_guard_observed()` reads the same rows
and flags, without deleting:

-   the placeholder EINs and names;
-   the filer’s own EIN written for a grantee;
-   a group central’s EIN written for one of its members;
-   a fiscal sponsor’s EIN written for many projects.

`vignette("corroborators")` lists the flags. Guarded observed names,
build of 2026-11-01:

| source               | observed names | placeholder EIN | placeholder name | own EIN | group central | many names |    any |
|----------------------|---------------:|----------------:|-----------------:|--------:|--------------:|-----------:|-------:|
| `schedi`             |      1,767,331 |          13,489 |              149 |   5,892 |        12,551 |     60,703 | 73,949 |
| `schedr`             |        187,999 |             704 |               55 |     599 |           229 |      1,067 |  2,054 |
| `efile990` (rosters) |          9,479 |               0 |                1 |       0 |             1 |          0 |      2 |

`md_compile()` always leaves `guard_any` rows out of a reference. The
two checks cover different errors:

-   a name written once, by mistake, is low on corroboration and usually
    unflagged;
-   a central’s EIN written for its congregations is often highly
    corroborated, and flagged.

</div>

<div class="section level2">

## From a name row to a reference

`md_spec(min_corroborators =)` keeps observed rows at or above the
threshold. It must be a band edge (1, 2, 5 or 20) because the corpus
statistics (`name_freq`, `token_idf`) are precomputed per layer, class
and band (`md_build_stats()`) and summed at compile time.

When several rows normalize to one `name_key` for an EIN (two spellings,
or two sources), the compiled row takes the largest `n_corroborators`
among them. When a spec caps the names per class (`max_names`), the most
corroborated names are kept first.

</div>

<div class="section level2">

## When a new release arrives

Statements are only ever added to the ledger. When a source publishes a
new release, `md_apply_release()` compares it with what the ledger
already holds for the same source and partition:

-   **new statements** are inserted;
-   **statements still there** have their `last_release` moved forward;
-   **statements the publisher withdrew** are marked `retracted_in`,
    never deleted. None have been withdrawn so far.

Then `name` and `address` are rebuilt from the whole ledger, so every
count above is recomputed from scratch. A new tax year of Schedule I can
raise a name’s `n_corroborators` and move it into a higher band. It can
also bring a first corroborator, so that a name starts out at one filer
and only later appears in the `*-observed` tiers. Because the counts are
rebuilt, not incremented, a rebuild from the same releases always gives
the same counts.

`vignette("updates")` describes the whole update, from a new source
release to published references.

<div id="cb4" class="sourceCode">

``` r
md_db_close(con)
```

</div>

</div>

</div>
