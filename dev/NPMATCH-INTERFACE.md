# A generic matching interface

**Status: proposal, 2026-08-23.** A design for `npmatch`, written from matchdb,
following the convention that cross-repo asks are argued here and land as pull
requests there.

npmatch was built for one task — SAM/USASpending against the BMF — and it does
that task well. The question is what has to change for it to do *other* tasks
without a fork, given that the next several consumers will have less information
rather than more.

---

## 1. What is rigid now, and what each rigidity costs

| rigidity | where | what it prevents |
|---|---|---|
| a fixed field contract | `np_fields` — one name, one dba, one division, one address block | a query with mission text, an org type, or a funder has nowhere to put it |
| `np_normalize()` computes all 19 columns, always, from fixed column names | `normalize.R:170` | normalising a long attribute table means building a throwaway wide frame and discarding half the output — measured, half of a 36-minute pass |
| a two-way weight split | `name_geo = c(0.6, 0.4)` | a name-only task still reserves 40% of the score for geography it does not have |
| blocking is one argument | `block = "state"`, plus a hand-written cascade | every new task rewrites the pass list from scratch |
| scoring rules are inline | `score.R` | whether a rule is separable can only be established by reading it — as §7 of `DECOMPOSITION.md` found out the hard way |
| no vocabulary for what a row *is* | — | a candidate that is an *affiliate* of the answer cannot be distinguished from the answer |

The through-line: npmatch knows what a match *is* but not what a task *has*.

---

## 2. A typed field schema

Replace the fixed contract with a declared one. Every field carries a source
column, a semantic **type**, and a **role**.

```r
schema <- np_schema(
  key     = np_field("ein",       type = "identity"),
  name    = np_field("org_name",  type = "name",        role = "primary"),
  dba     = np_field("dba_name",  type = "name",        role = "other"),
  street  = np_field("addr1",     type = "geo",  level = "street"),
  city    = np_field("city",      type = "geo",  level = "city"),
  state   = np_field("state",     type = "geo",  level = "state"),
  zip     = np_field("zip5",      type = "geo",  level = "zip5"),
  ntee    = np_field("ntee",      type = "categorical"),
  mission = np_field("mission",   type = "text"),
  funder  = np_field("filer_ein", type = "context")
)
```

**Type** determines the comparator, whether the field can block, and which weight
bucket it feeds. **Level** orders the geo hierarchy, which is what lets
`zip9 ⊂ zip5 ⊂ zip3` and domination pruning work generically rather than by
hard-coded knowledge of ZIP codes.

**Role** is the three-way distinction that does not exist today:

| role | meaning | consequence for scoring |
|---|---|---|
| `primary` | the entity's own canonical value | eligible for the distinctiveness promotion |
| `other` | another value for the **same** entity — dba, alias, former name | match on it, but its rarity says nothing about the entity |
| `related` | a value belonging to a **different, affiliated** entity | never evidence of identity |

`related` is the one that matters most and is entirely missing. 44% of group
parent/member pairs share an exact legal name, so "this candidate is its parent"
is not an edge case, and npmatch currently cannot represent it.

`np_fields` becomes the default schema rather than the only one, so existing
callers are unaffected.

---

## 3. Weights follow availability

The fixed `name_geo` split assumes both halves exist. Declare relative importance
per type instead, and renormalise over the types actually present **in both the
query and the reference**:

```r
np_weights(name = 0.60, geo = 0.40, text = 0.15, categorical = 0.05)
```

* name + full address → `name .60 / geo .40`, today's behaviour exactly
* name only → `name 1.00`
* name + state only → still `name .60 / geo .40`, but geo can only ever reach its
  state term, which is correct: weak geography should score weakly, not be
  reweighted into looking strong
* name + mission → `name .77 / text .19`, renormalised

The distinction that has to be got right: **a type absent from the schema** is
renormalised away, while **a field present but empty on a row** scores zero and
is not. Reweighting per row would let a record with no address earn a full score
on its name alone and outrank a record that matched on both.

---

## 4. Blocking as a declared plan

Blocking is currently one argument plus a cascade written by hand — pfmatch has
eleven passes. Make the plan a value:

```r
plan <- np_blocking(
  np_pass("name_key", "zip5"),
  np_pass("name_key", "state"),
  np_pass("name_token", "city"),
  np_pass("acronym",   "state"),
  np_pass("name_key")                    # last resort, no geography
)
```

Each pass names fields that must agree; the cascade runs them in order, dropping
queries already resolved, which is what `np_cascade()` does now with the list
inlined. Two things follow:

**A default plan can be derived from the schema.** Given which types are present
and their levels, propose the ladder — tightest geography first, widening, then
name-only. A task with no geography gets a name ladder without anyone writing
one.

**A pass must be able to name a `context` field.** For grants, the funder is a
blocking dimension: two grants from the same foundation naming the same recipient
are the same recipient, and that is a *query-side* fact with no reference
counterpart. npmatch has no way to express it, so pfmatch does it separately in
`pf_dedup()`.

Context has a second use worth separating. Independent funders naming the same
recipient is corroboration — the query-side mirror of `n_corroborators`, which
matchdb computes on the reference side. Same quantity, opposite direction, and
neither package currently connects them.

---

## 5. Comparators registered per type

```r
np_comparator("name",        jaro_winkler(threshold = 0.85))
np_comparator("geo:zip5",    exact())
np_comparator("geo:street",  jaro_winkler(threshold = 0.85))
np_comparator("text",        token_overlap_idf(min_len = 3))
np_comparator("categorical", exact_or_missing())
```

Adding mission text then becomes registering a comparator rather than editing the
scorer, which is the difference between a new field type being a day and a
release.

---

## 6. Rules that declare what they read

This is the part that comes directly out of the decomposition experiment, and it
is the most important item here.

`score.R` applies a distinctiveness promotion whose floor depends on `geo_state`.
Establishing that — and therefore establishing whether name and geography can be
scored separately — required reading the function. When the probe failed to
propagate `geo_state`, the answer was wrong by exactly 0.18, the gap between the
same-state and cross-state floors, **with nothing to indicate it**.

So a rule should declare its inputs:

```r
np_rule("distinctive_name_promotion",
  when  = name_score >= 0.95 & name_freq <= 3 & role == "primary",
  then  = floor(if_else(geo_state == 1, 0.90, 0.72)),
  reads = c("name_score", "name_freq", "role", "geo_state"),
  stage = "post_combine")
```

`reads` makes separability **mechanically checkable**: a rule reading only
name-type inputs decomposes; one reading both name and geo inputs must run
`post_combine` and must be handed the fields it names. A decomposed pipeline can
then verify at run time that everything a rule reads is available, instead of
silently producing a plausible wrong number.

`stage` matters for the same reason. The floor applied inside a per-type arm
gives a different answer from the floor applied after combining — the probe
confirmed the second is correct and the first is not.

---

## 7. What matchdb supplies

The reference side of this contract, already built or specified:

| field | type / role | status |
|---|---|---|
| `variant_class` | drives `role` | in `name` |
| `cluster_id` | `structure` | specified, `REDUCTION.md` §6a |
| `n_eins_sharing` | name ambiguity | specified, §6b |
| `n_corroborators` | reference-side corroboration | in `name` |
| `name_key`, `street_key`, … | derived | building now |

And the shape: matchdb should hand over **two tables, not one wide frame** — a
name table and an address table, both keyed on EIN. That is the decomposed form,
and `DECOMPOSITION.md` shows it produces identical scores at *k + m* instead of
*k × m*.

---

## 8. Migration

Nothing above requires a breaking change if it is staged:

1. `np_schema()` / `np_field()` added; `np_fields` becomes the default schema.
2. `np_normalize(fields =)` and explicit column mapping — additive, and recovers
   half of a 36-minute pass immediately.
3. `role` and `cluster_id` admitted to the schema, defaulting to `NA`, so
   existing callers are unaffected. This alone resolves §6b.
4. `np_weights()` renormalising over present types; the current two-way split is
   the special case.
5. `np_blocking()` as a value, with the existing cascade as the default plan.
6. Rules given `reads` and `stage`, one at a time, starting with the promotion.
7. Comparator registry.

Steps 2 and 3 are worth doing first: they are small, they are additive, and both
unblock work that is otherwise stuck.

---

## 9. What this design does not claim

It does not make matching *better*. Every change here is about what a task can
express, not about accuracy, and the accuracy questions in
`pfmatch/dev/OPTIMIZATION-PLAN.md` are untouched by it.

It also has a real cost: a declared schema is more to learn than a fixed one.
The justification is that the fixed contract is already being worked around —
pfmatch does its own dedup, its own dyad collapse, its own purpose tiebreak, and
matchdb builds a wide frame purely to satisfy a signature. Those workarounds are
the interface telling us what it is missing.
