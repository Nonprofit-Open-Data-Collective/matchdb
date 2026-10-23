# Add group-return rosters: the subordinate names the BMF throws away

When a central organisation files a group return it attaches a roster
naming every subordinate covered -
`AffiliateListing/AffiliateListingGrp` in the XML, with name, EIN and
address for each. It is the only source that states a group's membership
as a list rather than leaving it to be inferred from a shared GEN.

## Usage

``` r
md_ingest_affiliate_listing(
  con = NULL,
  path = NULL,
  guard = TRUE,
  version = "v2009-2013"
)
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- path:

  Path to a derived `affiliate-listing-*.csv`. `NULL` looks in the
  `version` source directory, preferring the published tables.

- guard:

  Run
  [`md_guard_observed()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_guard_observed.md)
  on the observed rows of source `efile990`.

- version:

  Pinned `efile_affiliate_listing` version, e.g. `"v3_1"`.

## Value

Row counts, invisibly.

## This is the source that recovers subordinate names

`GROUP-STRUCTURE-FINDINGS.md` §4 measured the problem: the BMF assigns
most subordinates the **parent's** legal name. Of 1,068 TY2013
affiliates matched to the BMF, **803 (75.2%)** carry a BMF name
different from the one they report for themselves, and in 70% of group
returns *every* member shares one identical BMF name. Five Einstein
subordinates all read "ALBERT EINSTEIN HEALTHCARE NETWORK" in the BMF
while calling themselves "Belmont Center For Comprehensive Tr",
"Einstein Practice Plan Inc" and so on.

So a subordinate's own name is usually **absent from the reference
entirely**, and this roster is where it lives. In a held-out retrieval
test (§5) these tokens were 0.19% of the index and carried 23% of the
gain - the best return per row measured anywhere in that work.

The names therefore land as `observed` variants on the subordinates'
**own** EINs. That is the narrow §10 exception, not a breach of it: the
roster states the subordinate's own name, not the parent's, so
registering it aliases nothing. The parent's name is never copied onto a
member.

## Two inputs

the published table, or the old extract: From e-file v2_3 on, the roster
is a published table, `F9-P00-T01-AFFILIATE-LISTING-<year>.CSV`,
covering every year (30,143 rows for 2009-2025 in v3_1). When
`sources/efile_affiliate_listing/<version>/` holds those files, they are
read. Otherwise the function falls back to the earlier derived extract,
`affiliate-listing-2009-2013.csv`, produced from raw XML before the
table existed. Both are pinned like any other source.

## The element was renamed in 2013

Returns through TY2012 use `AffiliateListing/Affiliate` with `Name/`,
`AddressUS/` and `NameControl`; TY2013 onward uses
`AffiliateListing/AffiliateListingGrp` with `BusinessName/`,
`USAddress/` and `BusinessNameControlTxt`. The extract normalises both
by matching on the field suffix. A run that returns rows for 2013 only
has silently hit the rename.

      2009    260 rows /  21 filings
      2010  1,630 rows /  66 filings
      2011  1,276 rows /  79 filings
      2012  1,204 rows /  88 filings
      2013  1,070 rows /  99 filings
      ----------------------------------
             5,440 rows / 353 filings / 2,515 distinct subordinate EINs

Coverage is thin by construction: only 99 of 483 TY2013 group filers
itemise members at all. This source is precise, not comprehensive.

## Direction and self-references

The filer of a group return is the central organisation, so the edge is
(filer, member, `group_member`) - the same direction as every other
group source. Rows where a filer lists its own EIN are self-loops and
are dropped.
