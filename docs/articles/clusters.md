<div id="main" class="col-md-9" role="main">

# Families: groups and clusters

Layers decide which organizations a record can be matched to, and name
and address classes decide which strings each one carries - see
`vignette("layers")`, `vignette("sources")` and
`vignette("corroborators")`. Families answer a third question: **when no
single EIN can be chosen, which set of EINs can.**

A chapter of a federation, a hospital and its system, a school and its
PTO: the evidence is often split, the name matching one organization and
the address another, so no candidate scores as a match while the family
plainly does. matchdb groups EINs so that the matcher can stop one level
up.

Two derived tables hold that grouping, and they are not the same thing.

|                                                  | built by              | id           | what it means                                                                     |
|--------------------------------------------------|-----------------------|--------------|-----------------------------------------------------------------------------------|
| `entity_group`                                   | `md_build_groups()`   | `group_id`   | one federated family, from the group-exemption edges in `ein_relation`            |
| `cluster`, `cluster_member`, `cluster_footprint` | `md_build_clusters()` | `cluster_id` | six **types** of family, including the groups above, each EIN in as many as apply |

Neither stores anything query-dependent. Both are facts about the
database; the matcher does the rest.

The counts below are from the build of 2026-11-01 (`matchdb@d632f21`,
normalizer `v1-592912060053c4c3`).

<div class="section level2">

## `group_id`: the federated families

`md_build_groups()` takes the connected components of the `group_member`
edges in `ein_relation`. Two EINs are in the same family exactly when
they share a `group_id`, so “are these two candidates the same family?”
becomes one join.

    group_member edges: 453,568, of which 447,311 are used and 6,257 set aside
    entity_group: 450,964 EINs in 3,700 groups (5 passes)
      group size: median 16, largest 17,902

Each row carries `ein`, `group_id`, `group_size`, `role` (`parent`,
`member` or `both`), `n_parents`, and `group_central_ein` - the parent
with the most members. EINs in no group get no row, so a `LEFT JOIN`
from `entity` gives them `NULL`.

**`group_id` is `"GRP-"` plus the digits of the smallest EIN in the
component**, e.g. `GRP-01-0347504`. It depends only on membership, so
rebuilding gives the same ids and adding an unrelated group moves no
existing one - unlike a row number. It carries no other meaning: the
smallest EIN is usually a member, not the parent. Use
`group_central_ein` for that.

**Why components, not the group exemption number.** One logical group
already spans several GENs (Lions 4, AAU 7, 4-H 12), and Rev. Proc.
2026-8 makes central organizations drop all but one ruling by
2027-01-22. A central EIN holding several GENs links them all, and a
member listed under two parents joins their groups - both of which a GEN
key would miss.

**One bad edge joins two families, so evidence is ranked.** A filer
writes another group’s GEN on line H(c), by typo or from an old ruling,
and in the first full build a high-school orchestra became a member of
both a youth soccer league and Parent Booster USA: one component of
25,739 EINs joining the US Catholic Conference, the Mayo Clinic, a
sorority and a motorcycle club. Each member’s edges are now filtered
before the components are taken, keeping only its best-ranked evidence:
the IRS’s own coding first, then the parent’s roster on its group
return, then an older GEN assignment, then the member’s own line H(c).
The first two are kept whole - a member the IRS or its parent places in
two groups is a real link. From the self-reported ranks a member keeps
one parent. The 6,257 set-aside edges stay in `ein_relation`; only the
components ignore them.

</div>

<div class="section level2">

## `cluster_id`: six types of family

`md_build_clusters()` writes one row per cluster, one per cluster and
EIN, and one per cluster, layer and state. An EIN can belong to many
clusters of different types.

| type              | prefix | clusters | memberships | median | largest | built from                                      |
|-------------------|--------|---------:|------------:|-------:|--------:|-------------------------------------------------|
| `group_exemption` | `GRP-` |    3,700 |     450,962 |     16 |  17,902 | `entity_group`, above                           |
| `related_system`  | `SYS-` |   95,283 |   1,077,889 |      2 |   1,023 | Schedule R, one star per discloser              |
| `care_of_network` | `ICO-` |    2,648 |       8,818 |      2 |     265 | in-care-of values naming one other organization |
| `shared_website`  | `WEB-` |   30,722 |     108,075 |      2 |   1,557 | website or email-domain keys held by 2+ EINs    |
| `brand`           | `BRD-` |      531 |     351,921 |     78 |  25,276 | a concentrated name word                        |
| `co_tenant`       | `CTN-` |  665,578 |   1,468,118 |      2 |       3 | **a shared street address**                     |

Together: 798,462 clusters over 1,655,813 EINs.

`cluster` carries `cluster_id`, `cluster_type`, `central_ein` (`NULL`
where the type has none), `size`, `label` and `brand_tokens` - the name
words held by at least half the members of a cluster of three or more,
most shared first, which is what a cluster-level name comparison looks
for: `ROTARY`, not `CLUB`. `cluster_member` carries `role` (`central`,
`parent`, `intermediate`, `member`) and `evidence`. `cluster_footprint`
counts members per cluster, layer and state; layers partition EINs, so
the footprint of any layer selection is the exact sum of its rows, the
same rule as `ein_key_layer`.

</div>

<div class="section level2">

## Clustering by address

`co_tenant` is the type built from addresses, and it is much the
largest.

The key is the one npnormalize produces: `street_key` and `zip5`, stored
in `ein_key` under kind `place` (see `md_place_key()`), so a lookup from
npmatch never misses on spelling. A cluster forms where **2 to
`max_cotenants` EINs (3 by default) report the same place as their own
current address.** A grantmaker writing a grantee’s address is not
occupancy.

Shared places of four or more are mostly registered agents, processing
centres and national headquarters, which say nothing about affiliation.
Stopping at three is what keeps this a family rather than a mailing
list: 852K pairs sit at places shared by 2-3 EINs, and only 5.7% of
those pairs are already in `ein_relation`, so this is the largest new
source of family links - and the least verified of the six.

**The place class gates it.** Where `md_build_places()` has run, a
co-tenant family forms only at a place whose `place_class` is `cluster`
and which is not flagged `care_of`, `cmra` or `agent_churn`. An
accountant’s c/o address, a mailbox store or an agent’s address with a
churning client list holds unrelated organizations however few of them
there are.

`place_class` is npnormalize’s own address classification, the four
labels `np_addr_freq()` returns, rebuilt over the database by the same
rule and thresholds:

    place: 278,930 shared places (cluster 268,801, building 4,873,
           shared 2,824, federated 2,432); place_unit: 35,439 shared suites

-   `federated` - crowded, and one name dominates: a national office its
    chapters file from.
-   `building` - crowded, with two or more recorded suites and enough
    suite coverage to believe them.
-   `shared` - crowded, names spread: a fiscal sponsor or an agent.
-   `cluster` - a handful of EINs, usually an organization with its
    foundation. This is the only class that becomes a family.

The `place` table adds what the run-time statistic cannot see:
private-mailbox suites, in-care-of agents, bank and trust shares, group
rulings among the occupants, and churn over every EIN that has ever had
the address. Those are the flags above.

</div>

<div class="section level2">

## Which package does what

The grouping is split across the stack on purpose, and the id is only
ever assigned in one place.

| package     | its part                                                                                                                           | assigns an id?                      |
|-------------|------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------|
| npnormalize | the keys the grouping groups on (`street_key`, `street_unit_id`, `zip5`, `name_key`) and `np_addr_freq()`, a per-address statistic | no                                  |
| **matchdb** | **builds and stores `group_id` and `cluster_id`**                                                                                  | **yes**                             |
| npmatch     | reads them at match time: `np_pair_links()`, `np_cluster_rollup()`                                                                 | no                                  |
| pfmatch     | its own query-side identity collapse, `pf_dedup()` to `recipient_uid`                                                              | yes, but of grant rows, not of EINs |

The last row is a different layer, easily confused with this one.
pfmatch groups *its own records* - repeated grant rows that are one
recipient - on `(name_key, street_key, zip5)`, so that a match found for
any member propagates to all of them. matchdb groups *reference EINs*
into families. A pfmatch run uses both.

</div>

<div class="section level2">

## Using them

A compiled reference carries the families of the organizations in it:

<div id="cb3" class="sourceCode">

``` r
b <- md_reference("active-observed", fetch = "missing")
b$clusters
```

</div>

npmatch reads that alongside the scored candidates. `np_pair_links()`
reports whether a query’s top two candidates are one family - a tie
between relatives is a family to settle, a tie between strangers is a
real ambiguity - and `np_cluster_rollup()` handles split evidence. On
1,984 Schedule I records with a known EIN, the roll-up placed 60 of 739
non-YES records in a family, and the true EIN was in that family 90% of
the time. `vignette("matchdb")` section 6 works through both.

To look at one organization’s families, `md_cluster()`:

<div id="cb4" class="sourceCode">

``` r
md_cluster("39-1925617", types = c("related_system", "shared_website"))
#> <md_cluster> EIN-39-1925617: 4 clusters (related_system 3, shared_website 1)
#>
#>   SYS-87-4664285  related_system, 2 members  BOYS & GIRLS CLUB OF DANE COUNTY FOUNDATION INC
#>       EIN-87-4664285  BOYS & GIRLS CLUB OF DANE COUNTY FOUNDAT WI
#>     * EIN-39-1925617  BOYS AND GIRLS CLUB OF DANE COUNTY INC WI
#>   ...
```

</div>

`size` always reports the full count, while `max_members` limits what is
listed - a brand cluster can hold 25,000.

A narrow layer choice can split a family: a chapter may be
`bmf_inactive` while its parent is `bmf_active`. `md_compile()` reports
that in its absence report, per cluster type.

<div id="cb5" class="sourceCode">

``` r
r <- md_compile(md_spec(layers = "bmf_active"))
r$report$absence
```

</div>

</div>

<div class="section level2">

## What each type had to be guarded against

-   **`related_system` is a star, never a component.** Chained together,
    Schedule R edges make one component of 117,869 EINs across the
    health and university sectors. Each discloser instead gets its own
    cluster of the entities it lists, and overlapping stars are kept as
    they are.
-   **Most in-care-of values are not organizations.** Of 1.6M values,
    1.05M are people, 103K roles or titled people, 32K agents and 16K
    the organization’s own name. A value is used only when it is none of
    these, names exactly one EIN’s legal or dba name in two or more
    words, and is in the same state. The state rule is what separates a
    person from the eponymous foundation (`CALVIN JONES` /
    `CALVIN JONES FOUNDATION`). This type needs the `peopleparser`
    census name table.
-   **`brand` took three passes.** Letting every concentrated word be a
    brand gave `STATES` 42,951 EINs and `CLUBS` 40,685. One brand per
    dominant name, anchored on its most concentrated word, gave `LIONS`
    rather than `CLUBS` - but the anchor still took every use of the
    word, so `COLUMBUS` gathered Columbus, Ohio. An anchor with other
    uses now also needs a second word of the brand’s name, trailing S
    ignored: `SPRINGFIELD LIONS CLUB` is in, `DETROIT LIONS` and
    `COLUMBUS SYMPHONY` are not. This type is what reaches the 63% of
    Toastmasters clubs that are in no group exemption.
-   **`co_tenant` stops at three, and reads the place class** - above.

Placeholder EINs (`0`, `123456789`) and EINs absent from `entity` are
dropped from every type: a cluster holding a placeholder would be a
false family. A star whose only listed entities fell outside `entity` is
one EIN, not a cluster, and clusters of one are not written.

</div>

<div class="section level2">

## What this does not do

-   **No levels.** Clusters do not nest into chapter, state body and
    national.
-   **No merging.** Overlapping clusters are left overlapping; the
    consumer sees every membership and decides.
-   **No scoring.** What a family is worth is npmatch’s judgement, and
    `np_cluster_rollup()` annotates rather than changing the EIN-level
    tier. Whether a `CLUSTER` match counts as a resolution is the
    analysis’s choice.
-   **Not fully validated.** The brand and co-tenant types in particular
    should be checked against held-out federated cases before a matcher
    leans on them.

</div>

<div class="section level2">

## Rebuilding

Both builders drop and rebuild, and the order matters:
`md_build_groups()` before `md_build_clusters()`, since
`group_exemption` reads `entity_group`, and `md_build_places()` before
it too, so that `co_tenant` can read the place class.
`md_build_groups()` reads only `ein_relation` and keys on EINs rather
than on reassigned row ids, so a re-ingest leaves it out of date rather
than broken. Rebuild after any ingest that writes `group_member` edges.

<div id="cb6" class="sourceCode">

``` r
con <- md_db()
md_build_groups(con)
md_build_places(con)
md_build_clusters(con)
md_db_close(con)
```

</div>

</div>

</div>
