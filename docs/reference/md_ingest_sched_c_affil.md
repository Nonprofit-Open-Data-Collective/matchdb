<div id="main" class="col-md-9" role="main">

# Add the Schedule C affiliated-group roster

<div class="ref-description section level2">

An organisation that has made the §501(h) lobbying election and belongs
to an affiliated group must list, in Schedule C Part II-A, every member
of that group with name, address, EIN, expenses and share of excess
lobbying expenditures. `AffiliatedGroupSchedule/AffiliatedScheduleGrp`
in the XML.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ingest_sched_c_affil(con = NULL, path = NULL, version = "v2009-2013")
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A connection from `md_db()`.

-   path:

    Path to a derived `sched-c-affiliated-group-*.csv`. `NULL` looks in
    the `version` source directory, preferring the published tables.

-   version:

    Pinned `efile_sched_c_affil` version, e.g. `"v3_1"`.

</div>

<div class="section level2">

## Value

Row counts, invisibly.

</div>

<div class="section level2">

## It is a different concept from group exemption, and must stay one

A §501(h) affiliated group is defined by interlocking governance under
§4911 - one organisation bound by another's decisions on legislative
issues, or enough board overlap to control them. That is a **control
test**, not the group exemption process, so these edges must never enter
the `group_id` components (`GROUP-STRUCTURE-FINDINGS.md` §2).

They land as `related_entity` (§4a), the same value Schedule R Part II
uses, and the measured overlap is the argument: **834 of 886 edges (94%)
already exist as a Schedule R Part II edge**. A looser coordination tie
- a `coalition` in the §4a sense - would not overlap Schedule R that
heavily. The word "affiliated" in the statute names a control
relationship, not a federated chapter structure.

</div>

<div class="section level2">

## It is reciprocal, which is why the self-loops matter

Every electing member reports the *whole* group, so a five-member group
produces five rosters that each name all five. In TY2013, **78 of 123
filers list their own EIN**, and 652 rows collapse to 339 distinct
member EINs. Self-references are dropped; the rest are stored in the
disclosed direction (filer -> member) like every other relation, and a
consumer wanting the undirected view reads the pair both ways.

</div>

<div class="section level2">

## It is nearly redundant, and is loaded anyway for the provenance

Measured on TY2013, **394 of 430 undirected pairs (91.6%) already exist
as Schedule R Part II edges**. This source adds tens of pairs, not
thousands.

It earns its place on the `evidence` tag rather than the coverage: an
edge corroborated by both a Schedule R disclosure and a §501(h)
affiliated-group filing is a stronger claim than either alone, and only
this ingest can say so. Loading it to inflate the row count would be the
wrong reason.

</div>

<div class="section level2">

## Two inputs

the published table, or the old extract: From e-file v2_3 on, this is
the published table `SC-P02-T01-AFFILIATED-GROUP-<year>.CSV` (21,091
rows for 2009-2025 in v3_1), read when
`sources/efile_sched_c_affil/<version>/` holds it. Otherwise the
function falls back to the earlier local extract of raw XML, described
below. Through TY2012 the element is
`AffiliatedGroupSchedule/AffiliatedSchedule` with `AddressUS/`; from
TY2013 it is `AffiliatedScheduleGrp` with `USAddress/`. The extract
matches on field suffix to serve both.

<div class="sourceCode">

      2009  355 rows /  58 filings
      2010  543 rows /  90 filings
      2011  554 rows /  98 filings
      2012  761 rows / 117 filings
      2013  652 rows / 123 filings
      ---------------------------------
           2,865 rows / 486 filings / 459 distinct member EINs

</div>

</div>

</div>
