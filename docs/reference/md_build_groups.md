<div id="main" class="col-md-9" role="main">

# Build `group_id`: the federated families in `ein_relation`

<div class="ref-description section level2">

Takes the connected components of the `group_member` edges in
`ein_relation` and stores one row per EIN that belongs to a group, as
the derived table `entity_group`. Two EINs are in the same family
exactly when they share a `group_id`, so the question
`pfmatch/R/dyads.R` recomputes per query - *are these two candidates the
same family?* - becomes one join.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_build_groups(con = NULL, max_iter = 100L)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A connection from `md_db()`.

-   max_iter:

    Upper bound on label-propagation passes. Each pass moves the
    smallest EIN at least one hop, so this bounds the longest path in a
    component. The real edges converge in a handful; reaching the bound
    is an error, not a silent partial answer.

</div>

<div class="section level2">

## Value

Invisibly, a one-row data frame: edges, EINs, groups, the largest and
median group size, and the passes taken.

</div>

<div class="section level2">

## Details

This is the `cluster_id` of `REDUCTION.md` section 6a, under the name
the schema uses (`PLAN.md` section 4, `GROUP-STRUCTURE-FINDINGS.md`
section 1).

</div>

<div class="section level2">

## Only `group_member` edges

`related_entity` and `disregarded_entity` edges never enter the
components. Unioned in, they join the health-system and university
sectors into one component of 117,869 EINs (`RELATION-BUILD-PLAN.md`).
Those edges will feed a separate `related_entity_id`, which needs its
own guard. Edges with no counterparty EIN (`ein_b` NULL) and self-loops
are skipped.

</div>

<div class="section level2">

## Why components, not the GEN

A group exemption number cannot be the key: one logical group already
spans several GENs (Lions 4, AAU 7, 4-H 12), and Rev. Proc. 2026-8 makes
central organisations drop all but one ruling by 2027-01-22. A central
EIN holding several GENs links them all, and a member listed under two
parents joins their groups, which a GEN key would miss.

</div>

<div class="section level2">

## One bad edge joins two families, so evidence is ranked

Connected components are only as good as the weakest edge: a single
member listed under two parents joins their groups. In the first full
build that happened through self-reported evidence. A filer writes
another group's GEN on line H(c), by typo or from an old ruling, and a
high-school orchestra became a member of both a youth soccer league and
Parent Booster USA. The result was one component of 25,739 EINs joining
the US Catholic Conference, the Mayo Clinic, a sorority and a motorcycle
club.

So each member's edges are filtered before the components are taken.
Only its best-ranked evidence counts, in this order:

1.  `bmf_group_exemption` - the IRS's own coding.

2.  `efile_affiliate_listing` - the parent's own roster on its group
    return.

3.  `nccs_group_metadata_historical` - an older GEN assignment.

4.  `efile_group_exemption_number` - the member's own line H(c).

5.  anything else.

The first two are kept whole: a member the IRS or its parent places in
two groups is a real link. From the self-reported ranks a member keeps
one parent, the one it reported in the most filings (then the latest,
then the smallest EIN). The set-aside edges stay in `ein_relation`; only
the components ignore them.

</div>

<div class="section level2">

## How `group_id` is named

`group_id` is `"GRP-"` followed by the digits of the smallest EIN in the
component, e.g. `GRP-01-0347504`. It depends only on the component's
membership, so rebuilding gives the same ids, and adding an unrelated
group moves no existing one - unlike a row number. It carries no other
meaning: the smallest EIN is often a member, not the parent. Use
`group_central_ein` for the parent.

</div>

<div class="section level2">

## Columns

-   `ein`:

    an EIN that appears in at least one `group_member` edge

-   `group_id`:

    the family, as above

-   `group_size`:

    EINs in the component

-   `role`:

    `parent` (only ever `ein_a`), `member` (only ever `ein_b`), or
    `both` - an EIN that is a parent in one edge and a member in another

-   `n_parents`:

    distinct parents this EIN is a member of; above 1 is what joins two
    stars into one family

-   `group_central_ein`:

    the parent with the most members in the component; ties go to the
    smallest EIN

EINs in no group get no row. A `LEFT JOIN` from `entity` gives them
`NULL`.

</div>

<div class="section level2">

## Rebuild after any relation ingest

Like `md_build_compact()`, this drops and rebuilds. It reads only
`ein_relation`, keyed on EIN rather than on reassigned row ids, so a
re-ingest leaves it out of date rather than broken. Rebuild it after any
ingest that writes `group_member` edges.

</div>

</div>
