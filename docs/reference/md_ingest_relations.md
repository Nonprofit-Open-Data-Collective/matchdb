<div id="main" class="col-md-9" role="main">

# Build ein_relation from Schedule R and the group exemption structure

<div class="ref-description section level2">

Section 10 is emphatic that group and related-entity structure belongs
in a relation table rather than the name table: group subordinates and
affiliate chapters are *distinct EINs with near-identical names*, which
is precisely the condition that produces false matches. Registering
"BOYS AND GIRLS CLUB OF SPRINGFIELD" as an alias of the national EIN
would make disambiguation worse, not better.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ingest_relations(version = "v2_2", con = NULL, bmf_version = NULL)
```

</div>

</div>

<div class="section level2">

## Arguments

-   version:

    Pinned `efile_related` version.

-   con:

    A connection from `md_db()`.

-   bmf_version:

    The `bmf_unified` version the group edges are read from. `NULL`
    reads it from `source_vintage`: the version that loaded `entity`.

</div>

<div class="section level2">

## Value

Row counts, invisibly.

</div>

<div class="section level2">

## Details

matchdb's job is to record the relation with provenance. What to do with
it - collapse, veto, or ignore - is a matching decision and lives in
`pfmatch` (`R/dyads.R`, `R/affiliation.R`).

</div>

<div class="section level2">

## Self-references are dropped, and that is not the same as worthless

4,133 filers list their own EIN as a related organisation. An edge from
an entity to itself is meaningless as a graph edge and distorts every
degree statistic computed over the table, so they are dropped and
counted.

But the first version of this note claimed they "carry no information",
and that was wrong. Checked against the filer's own BMF name, **61.7% of
self-references disclose a DIFFERENT name under the same EIN**, and the
examples are exactly the cases where IRS reporting structure and
operating reality diverge:

<div class="sourceCode">

      BACKBONE HOUSING INC          -> Backbone Housing Inc (dba Starner Hill)
      FRANCISCAN HEALTH SYSTEM      -> Franciscan Health System FKA Franciscan ...
      EMBANKMENT SERVICES INC       -> EMBANKMENT SERVICES INC (ESI)
      AMERICAN POSTAL WORKERS UNION -> APWU EMPLOYEES' RETIREMENT 401K PLAN
      ALABAMA SCHOOL OF FINE ARTS FOUNDATION -> Alabama School of Fine Arts
      Catalight Foundation          -> Impact Together

</div>

Those are DBAs, former names, acronyms, and genuinely distinct
programmes operating under one exemption - a parish and its school, a
foundation and the school it supports, a union and its benefit plan.
Real information, and the kind a matcher wants.

It is not lost by dropping the edge, because what is useful about it is
a **name**, and names are not this function's job. `md_ingest_schedr()`
already writes every Part II counterparty name as an `observed` variant
on the counterparty's EIN - which for a self-reference is the filer's
own EIN. Measured: **4,116 of the 4,133 (99.6%) are already registered
there**. The edge is redundant; the alias is not, and it survives.

</div>

<div class="section level2">

## `relation_raw` carries the controller, not the activity

An earlier version put `SR_02_RLTD_ORG_PRIMARY_ACT` here, so Part II's
raw values read `HOSPITAL`, `HEALTHCARE`, `low-inc hsng`, `FUNDRAISING`.
That is the counterparty's *activity* - a property of the organisation,
not of the relation - and §4 reserves `relation_raw` for the source's
own wording of the **relation**.

On this form that is the direct controlling entity, with an explicit
`N/A` where the filer states there is none. Population across 2009-2024:

<div class="sourceCode">

      rows                        6,540,823
      direct controlling entity   4,501,572  (68.8
      explicit 'N/A'                950,837  (14.5
      primary activity            6,226,371  (95.2

</div>

Losing the activity costs nothing here, and only here: Part II
counterparties are exempt organisations by definition and **119,865 of
119,865 (100%) resolve into `entity`**, so each one's activity is
available from its own record. That is not true of Parts III and IV,
whose counterparties resolve at 5-9%.

</div>

<div class="section level2">

## `controlled_512` is the sharpest signal the form carries

`SR_02_RLTD_ORG_CTRL_512_X` - is the counterparty a §512(b)(13)
controlled entity - is a statutory yes/no, **93.1% populated** (2.07M
true, 4.02M false) against 68.8% for the controller name. It is what
splits `related_entity` into controlled-by versus merely-related, and it
is the only column on the form that answers that question directly
rather than by inference from a name.

It is encoded four ways across schema versions - `0`/`1` and
`false`/`true` - so both forms are normalised. Anything else becomes
`NULL`: a blank box is silence, not a denial, and coercing it to `FALSE`
would invent 449,599 assertions nobody made.

Aggregating to one row per pair uses `bool_or`, so a pair is `TRUE` if
the filer asserted control in **any** year. The alternative - `bool_and`
- would let one year with the box blank erase a control relationship
stated in every other year.

Only Part II populates it. It is `NULL` for every other source, which is
honest: no other disclosure asks the question.

</div>

<div class="section level2">

## Direction is fixed, not doubled

A relation row reads **"`ein_b` is a `relation` of `ein_a`"**. Group
rows are stored once as (central, subordinate, `group_member`) rather
than also as the inverse `group_parent`, because storing both directions
doubles the table to say nothing new. Consumers that want the reverse
read the pair backwards.

</div>

<div class="section level2">

## Why group membership is not a clique

647,569 EINs carry a group exemption number, and 108 groups have more
than a thousand members - one has enough that a member-to-member clique
would emit hundreds of millions of pairs on its own. So membership is
recorded as parent-to-member, which is linear in group size.

That requires identifying the parent, and the BMF `affiliation_code`
does it. The codes are **not ordered by seniority**, which is a trap
worth spelling out because an earlier version of this function fell into
it:

<div class="sourceCode">

      1  NETWORK-PARENT            parent, no group exemption
      2  NETWORK-INTERM            intermediate, no group exemption
      3  INDEPENDENT               unaffiliated
      6  GROUP-EXM-PARENT-REGULAR  parent of a group ruling
      7  GROUP-EXM-INTERM          intermediate within a group ruling
      8  GROUP-EXM-PARENT-CHURCH   parent of a group ruling, church or 501(c)(1)
      9  SUBORDINATE               subordinate in a group ruling

</div>

**8 is a parent, not a subordinate.** Reading the codes as ascending
seniority puts 713 church parents on the member side of their own groups
and never uses them as parents. Parents are therefore `6` or `8`;
members are `7` or `9`.

Intermediates are deliberately treated as members only. A `7` is
genuinely dual-role - a member of the central organisation and a parent
to subordinates beneath it - but nothing in the BMF says *which*
subordinates report to which intermediate, so emitting
intermediate-to-subordinate links would be inventing a hierarchy the
data does not contain. One level, honestly.

Groups with no coded parent produce no rows rather than a guessed one,
and the count of those is reported.

</div>

<div class="section level2">

## Group exemption is not the whole of federated structure

Measured on the active BMF, a GEN and a group-exemption role are two
encodings of one fact: no EIN carries a GEN without a group role, and
only nine carry a group role without a GEN.

But **4,500 active organisations are coded `1` or `2` - network parents
and intermediates with no group exemption at all**. Affiliate structure
does not require the group exemption process, and this ingest does not
reach it, because a network has no GEN and therefore no key to join
members on. This is exactly why the `affiliate` relation (§4a) is
defined and holds zero rows. Worse, network *subordinates* are not
separately coded - only nine subordinates lack a GEN - so those 3,459
network parents have members that cannot be identified from the BMF at
all.

That gap is what Schedule R covers: disclosure does not depend on group
exemption, so an affiliate relationship outside a group ruling still
appears there. The two halves of this function are complementary rather
than overlapping.

</div>

<div class="section level2">

## Schedule R gives both EINs, and sometimes only one

Part II lists related tax-exempt organisations with an EIN, so most rows
resolve to a pair. Where the EIN is absent the row is still kept, with
`ein_b` null and `related_name` carrying the counterparty as written -
resolving a name to an EIN is a *matching* problem, which is npmatch's
job, not something an ingest should guess at.

</div>

</div>
