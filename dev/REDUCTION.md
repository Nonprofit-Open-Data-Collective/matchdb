# From archive to working set

**Status: proposal, 2026-08-22.** Companion to [`PLAN.md`](PLAN.md) §5–§8.

> Section references written bare — §8, §10, §6c — point at `PLAN.md`.
> References to this document say so explicitly.

Ten sources are ingested and all five core tables are populated. This document
is about the step that has not been taken: turning 43 million rows of archive
into a reference small enough to match against and sharp enough to be worth
matching against.

---

## 1. The problem, in one table

| table | rows | |
|---|---:|---|
| `entity` | 4,016,683 | |
| `name` | 9,665,441 | |
| `address` | 18,546,417 | |
| `ein_relation` | 1,306,825 | |
| `orgtext` | 15,072,111 | 5 GB |

Against measured cascade cost (`pfmatch/dev/REF-PERFORMANCE.md`): 1.92M reference
rows cost 128 s per 1,000 identities, 3.89M cost 226 s, and the full 12.5M-grant
run at 3.89M rows is **66–81 hours on 12 shards**.

Scaling is sublinear — 1.77× time for 2.02× rows, an exponent near 0.82 — but a
naive compile of what is now loaded produces on the order of 15–25M reference
rows. That is 4–6× today's reference, which extrapolates to roughly **300 hours**
for the same run. The archive has outgrown what can be matched against.

**So the compile step is not a formatting exercise. It is the point.** The
database may be enormous; the reference must not be.

---

## 2. The organising principle

A reference row earns its place by being **discriminative** — by raising the
chance that a query resolves to exactly one organisation. Rows that cannot do
that are not neutral: they cost blocking time, they generate candidates that
must be scored and rejected, and some of them actively cause false matches.

Three questions, applied to every row:

1. **Is it redundant?** Two rows that normalize to the same key for the same EIN
   are one row.
2. **Is it discriminative?** A name held by 21,173 organisations identifies none
   of them.
3. **Is it true of an organisation at all?** Some of what has been loaded
   describes people, not organisations.

Everything below is those three questions applied table by table, with what the
data says.

---

## 3. Three roles, and three ways to process them

The tables do not hold one kind of thing. They hold three, and which one a row
belongs to decides what it becomes at compile time. The current schema makes the
distinction half-way — `name`/`address` on one side, `ein_relation` on the other
— but treats them as parallel tables to be processed alike, and they are not.

### What each table actually asserts

**Alternative identity** — *the same organisation, written differently.*

| table | classes | rows |
|---|---|---:|
| `name` | `legal` 4,998,567 · `observed` 1,912,147 · `dba` 981,303 · `former` 197,251 | 8,089,268 |
| `address` | `historical` 12,390,751 · `mailing` 3,848,551 · `observed` 2,307,115 | 18,546,417 |

**Affiliate structure** — *different organisations, related to each other.*
`ein_relation`, 1.3M rows and growing.

**Neither** — `in_care_of` (1,576,173 rows naming a *person*, this document §4) and `orgtext`
(adjudication input, this document §7).

### The two categories have opposite economics

| | alternative identity | affiliate structure |
|---|---|---|
| what it buys | **recall** — another way to find one organisation | **precision** — how to choose between organisations |
| compiled form | **rows** in the reference | **a column** on `entity` |
| marginal cost | multiplies reference size and blocking time | **zero reference rows** |
| the §8 row budget | fully subject to it | exempt |
| risk of adding more | false matches, row blowup | none to recall |

So the disciplines are **inverted**, and this is the practical consequence:

**Alternative identity should be minimally inclusive.** Every class added
multiplies rows, and some actively harm — `in_care_of`'s 1.58M personal names,
the 690,200 rows sitting on hundred-way-ambiguous keys, the 5.3M addresses more
than a decade stale. Each class earns its place against a budget or it does not
go in.

**Affiliate structure should be maximally inclusive.** More relations strictly
improve `cluster_id` and cost nothing, because the graph collapses to one integer
per entity before the reference is built. There is no reason to be selective
about Schedule R, group exemption, 527 disclosures or anything else that names
two EINs — take all of it, from every source that offers it.

Those two sentences pull in opposite directions, which is why processing the two
halves with one discipline gets both wrong.

### The boundary case, and why it holds

`dyad_substitutable` and `successor` look like identity. They assert that two
EINs are interchangeable *for matching purposes*, which is exactly what
`pf_dyad_collapse()` acts on. But even those stay column- or lookup-shaped and
**never become reference rows**: they are consulted after blocking, to merge
candidates that were generated independently. Structure is used at selection
time; it is never compiled into the frame.

That boundary is load-bearing, and there is a number behind it. On a 396,892-pair
sample of group relations, **175,635 — 44% — connect two EINs with an exact
matching legal name.** Chapters really are called what their parent is called.

So the tempting move — registering the parent's name as an alias on each
subordinate's EIN, "so the chapter can be found" — would take an already
unresolvable case and make it worse, adding rows to a key that resolves to
nothing. §10 forbids it, and the 44% is why: the names are *already* identical
without anyone's help. What is missing there is not another spelling but a way to
choose, and choosing is what the structure side is for.

### The routing rule for anything that arrives next

When a new source appears, one question decides where it goes:

> **Does it give another way to *find* an organisation, or another way to
> *choose* between organisations?**

* **Find** → an identity variant. It becomes rows, pays the row budget, needs a
  `variant_class`, must be deduplicated and must justify its discriminative
  value.
* **Choose** → structure. It becomes a relation, collapses into a column, costs
  nothing, and should be taken in full.
* **Neither** → it is context. `orgtext` is the model: keep it in the database,
  ship a compact summary, join it on demand, and never let it near blocking.

Applied to what is already registered but unloaded: `irs527_related` is *choose*
(take all of it), `meta_names` is *find* (and must clear the truncation question
in `?md_meta_caveats` first), and `meta_group_return` is *neither* — a filing
arrangement that identifies nothing and relates nobody.

---

## 4. `name` — 9,665,441 rows

### The redundancy is modest

Deduplicating on `(ein, rough_key)` gives 8,133,990 distinct rows: **15.8%
saved**. The real `name_key` from `np_normalize()` will do better, because it
also folds abbreviations, strips legal suffixes and removes a leading "THE" —
call it 25%. Worth doing, not transformative.

### The discriminative structure is where the value is

| EINs sharing a name key | keys | rows |
|---|---:|---:|
| 1 — unique | 6,061,157 | 6,061,157 |
| 2–3 | 357,800 | 777,315 |
| 4–10 | 56,258 | 304,484 |
| 11–100 | 12,326 | 300,834 |
| **100+** | **1,269** | **690,200** |

**1,269 name keys account for 690,200 rows — 7.1% of the table — and each one
matches at least a hundred organisations.** They are pure cost: every query that
touches one generates a hundred candidates that all have to be scored and all
but one rejected.

And they are not random. The top of the list is:

```
TOASTMASTERS INTERNATIONAL                21,173 EINs
INTERNATIONAL ASSOCIATION OF LIONS CLUBS  17,279
KNIGHTS OF COLUMBUS                       12,820
AMERICAN LEGION                           12,042
4H CLUBS AFFILIATED 4H ORGANIZATIONS      11,920
THRIVENT FINANCIAL FOR LUTHERANS          11,297
```

Every one is a group-exemption chapter structure. **The name-collision problem
and the affiliate-structure problem are the same problem**, which is the central
observation of this document, and §6 below.

### One variant class is not organisations

`in_care_of` is 1,576,173 rows — 16% of the name table. Every row carries a `%`
c/o marker, and only **2.8% contain any organisational word** (INC, FOUNDATION,
ASSOCIATION, CHURCH, TRUST, …). A sample settles it:

```
% CARLOS ANDERSON      % JOANNE SOUSA       % BRENDAN BURKE
% FARAH ROMULUS        % JOHN FALLON        % FINANCE OFFICER
```

These are **personal names**. In a database of organisations, matching a query
against them is a false-match generator: a grant to "J FALLON MEMORIAL FUND"
should not attach to whichever EIN happens to list John Fallon as its treasurer.

**`in_care_of` should be off in every published spec, and should probably not be
a name class at all.** The c/o line is part of a mailing address — it is
plausibly useful for *verifying* an address, and not for identifying an
organisation. Its 1.58M rows are the single cheapest deletion available.

### Compact form

One row per `(ein, name_key)`:

```
ein, name_key, name_raw (modal, for display),
variant_class   -- highest precedence present: legal > dba > observed > former
source_mask     -- bitmask of attesting sources, not one row per source
n_corroborators -- max across sources
n_eins_sharing  -- how many EINs hold this key (precomputed, see §6)
first_year, last_year
```

`source_mask` matters: a name attested by the BMF, the 990 header and Schedule I
is currently three rows and should be one row with three bits set. Given the
overlap between BMF legal names and 990-header legal names, this is where most
of the remaining redundancy lives.

---

## 5. `address` — 18,546,417 rows

### Redundancy is larger here

Deduplicating on `(ein, street, zip5)` gives 13,030,740: **29.7% saved**. Most of
that is the same address recurring across vintages in the historical crosswalk,
which should collapse to one row carrying `first_vintage`, `last_vintage` and
`n_vintages` rather than one row per spell.

### Recency is the selection axis

| last vintage | rows |
|---|---:|
| 2020+ | 6,236,910 |
| 2015–19 | 2,813,146 |
| 2010–14 | 2,160,758 |
| pre-2010 | 3,149,968 |
| none recorded | 4,185,635 |

**5.3M rows (29%) are more than a decade stale.** A 2004 address does not help
match a 2023 grant and can actively hurt: it places an organisation somewhere it
no longer is, and geographic agreement is treated as evidence. Recency belongs in
the spec as a first-class filter, and the default should be recent.

### Co-tenancy destroys geographic evidence

| EINs at one address | addresses | rows |
|---|---:|---:|
| 1 | 6,186,745 | 6,186,745 |
| 2–5 | 792,415 | 1,905,864 |
| 6–50 | 53,434 | 567,319 |
| 51–500 | 1,317 | 152,775 |
| **500+** | **96** | **113,546** |

```
3700 GRAND AVE, 50312          6,866 EINs
1 WATERFOWL WAY, 38120         5,422
770 AUGUSTA RD, 29824          4,056
PO BOX 653067, 75265           3,744
```

These are national headquarters receiving mail for every chapter, and registered
agents. **Geographic agreement at such an address is worth nothing**, but the
scorer currently treats it as evidence like any other. Storing
`n_eins_at_address` lets a comparator discount it — and note this is the same
chapter structure again, seen from the address side.

### Compact form

One row per `(ein, street_key, zip5)`:

```
ein, name_id (the §8 pairing link), street_key, city, state, zip5, zip3,
variant_class, spell_rank, first_vintage, last_vintage, n_vintages,
n_eins_at_address,          -- precomputed co-tenancy
geocode_type, lat, lon, county, cbsa, tract
```

---

## 6. The latent structure: collisions *are* affiliations

This is the finding worth building on.

`TOASTMASTERS INTERNATIONAL` is held by 21,173 EINs. Those EINs are not
coincidentally similar organisations — they are **one group exemption**, and
`ein_relation` already links them to a common parent. The same is true of the
Lions Clubs, the Knights of Columbus, the American Legion, 4-H. And `1 WATERFOWL
WAY` with its 5,422 EINs is the same structure seen through the address table.

So the two hardest problems in this data — why a name matches a hundred
organisations, and which organisations are affiliates — have **one answer**.
That makes a derived feature available that neither table can produce alone.

### 6a. `cluster_id` on `entity` — the highest-value derivation

Take the connected components of `ein_relation` and stamp each EIN with a
cluster identifier. One integer per entity replaces traversing 1.3M pairs, and it
answers in O(1) the question `pfmatch/R/dyads.R` currently recomputes: *are these
two candidates the same family?*

### 6b. `name_ambiguity` — turning a count into a structural claim

For each `(name_key)`, compare the clusters of the EINs holding it:

| value | meaning | what a matcher should do |
|---|---|---|
| `unique` | one EIN | the name decides; promote |
| `within_family` | many EINs, one cluster | the name cannot decide; **geography must** |
| `cross_family` | many EINs, several clusters | genuine ambiguity; require strong corroboration |

This directly repairs a defect the plan already documents. `npmatch`'s
distinctive-name promotion fires on `name_freq <= 3` — a raw count that cannot
distinguish "three chapters of one body" from "three unrelated charities".
§8a measured the consequence: thinner references auto-accept *more*, because the
siblings that would have created a contest are absent. `name_ambiguity` makes
that visible in the data rather than emergent at match time.

It is also the honest form of the §6b question. A rare *legal* name is
meaningful; a rare name inside a 21,000-member family is not rare at all in the
sense the rule intends.

### 6c. Cheap derivations worth having

**`n_eins_at_address`** — down-weight geographic agreement at shared addresses,
and incidentally identify fiscal sponsors and registered agents.

**Temporal envelope veto.** `entity.first_vintage` / `last_vintage` against a
query's year. A 2020 grant to an organisation last seen in 1998 is almost
certainly wrong. No new data required — the columns exist and nothing uses them.

**Brand divergence.** EINs whose `observed` names differ substantially from their
`legal` name are exactly the organisations where legal-name matching fails. A
flag tells the matcher when the alias path is load-bearing.

**`successor`** — currently in the relation vocabulary and unpopulated. Derivable
from same `name_key` + non-overlapping entity lifespans + same state. It explains
why a query names an organisation that appears to have dissolved.

---

## 7. `orgtext` — 15,072,111 rows, 5 GB

The largest table by far, and the one whose compact form differs most from its
stored form. It is adjudication input, consumed *after* a candidate list exists
(§10), so the reference does not need the prose — it needs a comparable summary.

**One row per EIN carrying a cleaned, deduplicated token set** (or top-N TF-IDF
terms) collapses 15M rows to at most 787,518 — a 19× reduction, and turns 5 GB
into something on the order of 200 MB.

Keep the prose in the database for display and quotation; ship the token set.

Coverage bounds what this can do: mission text reaches **33.1% of active
organisations** and 19.6% of all entities, because only full Form 990 filers
answer the question. The cases it cannot reach are disproportionately the small
obscure ones where names are least distinctive — which is precisely where a
tiebreak would help most.

---

## 8. Proposed build order

Each step is cheap, and each one makes the next cheaper.

1. **Derived columns.** Run `np_normalize()` over `name` and `address`, store the
   output. §6c measures this at 66% of build cost and it drops to zero once
   stored. Nothing below is possible without it, and the normalizer signature
   currently guards artifacts that contain nothing derived.

2. **Collapse to compact form.** One row per `(ein, name_key)` and per
   `(ein, street_key, zip5)`, with `source_mask` and the vintage envelope.
   Expected: name 9.7M → ~7M, address 18.5M → ~13M.

3. **Precompute the structural columns.** `cluster_id`, `n_eins_sharing`,
   `n_eins_at_address`. All are single passes; all are database properties rather
   than spec properties, so they are computed once rather than per compile.

4. **`md_spec()` and `md_compile()`.** With the above in place, a compile is a
   filtered read plus the §8 pairing join — seconds, not minutes.

5. **Name the tiers by cost, and publish the shape.** A default reference should
   land near today's 3.89M rows, not 25M. Candidate default: legal + dba +
   corroborated observed names, current and recent addresses, `in_care_of`
   excluded, `name_ambiguity != cross_family` promoted.

---

## 9. What this is not

It is not a proposal to delete anything from the database. Every row loaded stays
loaded, with its provenance — that is what the archive is for, and the 1,269
worthless-for-matching name keys are perfectly good answers to "what is this
organisation called".

The reduction is a property of the **compiled reference**, chosen by a spec and
recorded in its hash. What this document argues is that the default spec should
be far more selective than "everything we have", and that the selection should be
driven by measured discriminative value rather than by which sources happened to
be easiest to ingest.
