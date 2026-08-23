# Scoring without the cross-product

**Status: proposal, 2026-08-23.** Answers three questions posed against
[`REDUCTION.md`](REDUCTION.md): when to dedupe and prune, whether npmatch's
interface should change, and whether name and address should be atomized.

The three have one answer between them, so the result comes first.

---

## 1. The result

`npmatch/R/score.R:57` computes

```r
score <- ng[["name"]] * name_score + ng[["geo"]] * geo_score
```

a weighted sum of a name term and a geography term. For an organisation with
names *n₁…n_k* and addresses *a₁…a_m*, the best score over the full cross-product
is

```
max over (i,j) of  α·N(q, nᵢ) + β·G(q, aⱼ)
  =  α · max over i of N(q, nᵢ)  +  β · max over j of G(q, aⱼ)
```

The maximum of a separable sum is the sum of the maxima. **Scoring names and
addresses independently and combining per EIN gives exactly the same answer as
materialising the cross-product — not an approximation of it.**

So the *k × m* expansion is not merely expensive. It is redundant: it computes
*k · m* sums in order to find a maximum that is determined by *k + m* terms.

### What it changes

| | cross-product | decomposed |
|---|---|---|
| reference rows per EIN | *k · m* | *k + m*, in two tables |
| name comparisons | *k · m* | *k* |
| geo comparisons | *k · m* | *m* |
| answer | — | **identical** |

At the current shape — 9.7M names and 18.5M addresses over 4M entities — the
cross-product is on the order of 25M+ rows against roughly 28M decomposed rows
that never multiply. The multiplication is what makes 20M+ intractable, and it
buys nothing.

### The one place it is not free

§8's *pairing rule* deliberately restricts emission to pairs actually observed
together: a Schedule I alias with the address the grantmaker wrote beside it.
Decomposition discards that constraint — an organisation is credited with its
best name and its best address whether or not they co-occurred.

That makes decomposition **exactly equal to full cross-product scoring and
strictly more permissive than constrained pairing.** The question of whether to
constrain is a modelling decision, separate from how to compute; but it should be
made knowingly. Both the name and the address are attested facts about that EIN.
Whether the same filer wrote them on the same line is weak evidence, and §8's
rule exists to control row count, which decomposition solves by other means.

---

## 2. Verified against the actual scorer

The weighted sum is separable, but `score.R` applies three adjustments after it.
Each was checked.

**Distinctive-name promotion — the one genuine cross-term.**

```r
promote   <- name_score >= 0.95 & nf <= maxfreq & informative & on_primary
floor_val <- ifelse(geo_state == 1, distinct_name_floor, distinct_name_floor_xstate)
score[promote] <- pmax(score[promote], floor_val[promote])
```

The trigger is name-only, but the floor depends on `geo_state` — whether the
states agree. It still decomposes, because `geo_state` is a property of the
geography side alone: carry it beside `max_geo_score` and the floor is
computable. **The decomposition needs to propagate `geo_state`, not just the
geo score.**

**Token-overlap cap** — keys on `name_match_type`. Name-only, separable.

**`geo_score` is already a `pmax`** over zip9 / zip5 / street / city / state
terms. Taking the max over an EIN's addresses is the same operation one level
up, which is a good sign the shape is natural rather than imposed.

**Not yet verified: the veto engine.** Vetoes are applied outside this function.
A veto that reads a name field and a geography field *of the same row* would not
decompose. This needs checking before implementation, and it is the single most
likely place for the result to break.

---

## 3. Task 1 — when to dedupe, and what to drop

Three operations, in this order, because each is cheaper once the previous has
run and only the first is lossless.

### 3a. Exact dedupe — lossless, do it always

Collapse `name` on `(ein, name_key)` and `address` on `(ein, street_key, zip5)`,
unioning provenance rather than keeping duplicate rows: a `source_mask` bitmask,
`max(n_corroborators)`, `min(first_year)`, `max(last_year)`.

Measured on the full tables: **15.8% of names and 29.7% of addresses.** (A
400,000-row sample showed only 0.2%, which is an artefact of sampling — duplicates
cluster *within* an EIN and a random draw rarely takes two rows for the same one.
The full-table figures are the real ones.)

### 3b. Domination pruning — lossless under a stated condition

An address **dominates** another when it agrees on every field the other
populates and populates at least one more:

```
(city=CHICAGO, state=IL)                          dominated by
(street=123 MAIN ST, city=CHICAGO, state=IL, zip5=60601)
```

Drop the dominated row. This cannot reduce recall **provided the comparator does
not penalise the reference for carrying detail the query lacks** — and npmatch
satisfies that: `geo_score` is a `pmax` over terms, and a term the query cannot
supply is `NA` and excluded rather than scored zero. The condition is stated
because it is a real dependency, not because it is in doubt today.

This is the answer to "should a city-and-state-only address survive next to a
full one for the same EIN?" — no, and dropping it costs nothing.

Names do not nest this way. `ALZHEIMERS ASSOC` and `ALZHEIMERS DISEASE AND
RELATED DISORDERS ASSOCIATION` have different keys and neither dominates: one is
the brand, the other the legal name, and both are needed. Names get exact dedupe;
addresses get domination.

### 3c. Quality ranking — threshold, with a cap as a backstop

**Threshold, not fixed structure.** A national charity with eight genuine trading
names should not be truncated to three, and a shell with one name should not be
padded. Organisations differ, and the decomposition removes most of the pressure
to cap: at *k + m* cost, one extra name is one extra row, not *m* extra rows.

A cap still belongs, per §7c — as a backstop against pathological EINs, applied
**per variant class** and with the deterministic total order §7c already
specifies. It is a safety net, not the mechanism.

The ranking that drives the threshold, in descending priority:

| rank | signal | rationale |
|---|---|---|
| 1 | `variant_class` | `legal` > `dba` > `observed` > `former`; `in_care_of` excluded entirely |
| 2 | `n_eins_sharing` | a key held by 21,173 EINs identifies none of them |
| 3 | `n_corroborators` | independent filers who wrote it |
| 4 | `last_year` / `last_vintage` | recency; 5.3M addresses are over a decade stale |
| 5 | `source_mask` popcount | attested by more sources |

The proposed default excludes: `in_care_of` (1.58M rows naming people), names
whose key is held by 100+ EINs *and* corroborated by one filer, and addresses
whose `last_vintage` predates a configurable horizon.

**These are spec parameters, not deletions.** The database keeps everything;
§9 of `REDUCTION.md` is unchanged.

---

## 4. Task 2 — what npmatch should expose

Three gaps, the first two found by writing the prototype against the current API.

**`np_normalize()` computes everything, always.** It returns all 19 derived
columns regardless of input, so normalising the long `name` table also computes
`street_key` and `zip3` over stub columns, and the `address` table pays
symmetrically for name parsing it will not use. Measured: 14.6 min and 21.7 min
respectively, roughly half of each wasted.

```r
np_normalize(data, fields = c("name", "address"))   # compute only what is asked
```

**It requires fixed column names.** `data$name`, `data$street`, `data$zip5`.
A long attribute table has `name_raw` and `street_raw`, so the caller builds a
throwaway wide frame to satisfy the signature. An explicit mapping would remove
that:

```r
np_normalize(d, name = "name_raw", street = "street_raw", zip = "zip5")
```

**There is no vocabulary for what a candidate row *is*.** §6b establishes that
`variant_class` must reach the scorer, and the promotion already approximates it
with `name_ver_y == "MAIN"`. The distinction wanted is three-way, and the third
value is the one nothing can currently express:

| status | meaning | what the scorer should do |
|---|---|---|
| `primary` | the organisation's own legal name | promotion eligible |
| `other` | another name for the **same** organisation — dba, alias, former | match on it, but do not promote on its rarity |
| `related` | a name belonging to a **different, affiliated** organisation | never treat as identity; a signal to disambiguate, not to accept |

`related` is the missing one. npmatch cannot presently distinguish "this candidate
is the organisation you asked about" from "this candidate is its parent". That is
precisely the case §10 warns about and the case that 44% of group pairs sharing an
exact legal name makes common.

**`cluster_id` has nowhere to live.** matchdb can produce it (`REDUCTION.md` §6a)
but `np_fields` has no slot, so it cannot travel into scoring or selection.
Adding `cluster_id` and `n_eins_sharing` to the field contract turns
`pf_dyad_collapse()` from a pfmatch-local computation into a lookup, and gives
the promotion rule the structural fact it currently lacks.

---

## 5. Task 3 — atomizing name and address

**The machinery already does this, at fixed arity.** `np_compare()` scores the
name / DBA / division cross-product and keeps the best — the comment at
`score.R:70` says so explicitly, and warns about the consequence: the statistics
attached to a pair may describe a different string than the one that matched.

So atomization is not a new idea to be introduced; it is an existing behaviour to
be generalised from three fixed columns to *n* rows. That is reassuring about the
shape and it also inherits a known defect: **whatever matched must carry its own
provenance**, or `name_freq` describes one string while the score came from
another. Decomposed scoring must return not just `max_name_score` but *which*
name achieved it, its `variant_class`, and its `n_eins_sharing`.

### The proposed interface

```
name_scores  <- score_names(query, name_table)      # -> ein, best_name_score,
                                                    #    winning name_id, variant_class,
                                                    #    n_eins_sharing, match_type
geo_scores   <- score_geo(query, address_table)     # -> ein, best_geo_score, geo_state
combined     <- join on ein; apply weights, promotion floor, caps
```

Blocking changes shape with it. Today the reference is one frame and both name
and geography are blocking dimensions over the same rows. Decomposed, **the name
table is the blocking surface and the address table becomes a lookup** — geography
filters or scores candidate EINs already generated, rather than multiplying the
rows blocking must scan. That is where the tractability comes from, more than
from the row count itself.

---

## 6. What this does not settle

**The veto engine is unverified** (§2). If any veto reads a name field and a
geography field of the same row, decomposition breaks there and needs a
compensating pass.

**Permissiveness is untested.** Decomposition equals full cross-product scoring,
but the current pipeline uses constrained pairing, so switching changes results.
The direction is more candidates scoring highly. That has to be measured on the
1k benchmark before adoption, not assumed benign — it is exactly the kind of
change `PROCESS.md` §3 says must be classified as behavioural rather than
representational.

**The gain is asserted, not measured.** The row arithmetic is certain; the
wall-clock consequence is not, because blocking cost depends on token
distribution rather than row count alone. A probe on one shard would settle it
and should precede any commitment.
