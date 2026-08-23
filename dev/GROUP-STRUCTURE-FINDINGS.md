# Group structure — what the evidence supports

**Measured 2026-08-22.** Normalizer signature `v1-421e1e2a6afb024e` throughout.
Every figure below is measured against `MATCHDB.duckdb`, the pinned
`BASELINE-2026-08` benchmark, or the TY2013 e-file extracts in
`~/Documents/ef2/`. Where a number was wrong in an earlier draft it is corrected
here with the reason, because two of the corrections reverse a conclusion.

Scripts are disposable and live outside the repo (session scratchpad); the
figures are the durable part. `bmf-normalized.rds` caches the 3.69M normalized
BMF legal names — any rerun should reuse it rather than pay the 8-minute
normalize again.

---

## 0. Decisions this produced

| proposal | verdict | why |
|---|---|---|
| `group_id` derived column | **build** | §3 — perfect YES specificity, 66.5% candidate reduction in affected cases |
| Ingest `AffiliateListing` names as `observed` | **build, pull forward** | §5 — 0.19% of tokens carried 23% of retrieval gain |
| `related_entity_id` from Schedule R | **build with a guard** | §2 — 33,206 components but a 37,163-EIN giant |
| Fold Schedule C into `relation='affiliate'` | **build** | §2 — 91.6% of its pairs already exist as Schedule R edges |
| `semantic_group_id` as stored state | **reject** | §4 — it is a function of the spec, not of the entity |
| `group_signature` token-union index | **reject** | §6 — +1.0 point rank-1 for +6% candidates |
| Address-union index | **reject** | §6 — median 154 groups returned per query |

---

## 1. What `group_id` is

Connected components over `ein_relation` where `relation = 'group_member'`.

```
edges                442,849   (439,936 bmf_group_exemption + 2,913 nccs historical)
distinct ein_a        3,643    parents
distinct ein_b      442,849    members, each appearing once
components            3,643    median 16 members, max 17,179
EINs covered        446,492    = 12.1% of 3,687,881 BMF EINs
```

The BMF edges are already a clean star topology, so components reduce to the
stars. Components are still the right derivation — they generalise to
affiliation code 7 (intermediate parents) and survive a member appearing under
two parents across vintages.

**GEN cannot be the key.** A single logical group is already fragmented across
multiple GENs today, before Rev. Proc. 2026-8 forces central organisations to
terminate all but one ruling by 2027-01-22: Toastmasters spans 2 GENs, Lions 4,
American Legion 5, AAU 7, 4-H **12**. GEN is evidence feeding a surrogate key,
never the key.

## 2. `related_entity_id` and Schedule C

```
Schedule R Part II edges       863,976
components                      33,206 over 143,145 EINs
largest component               37,163 EINs        <- needs a guard
```

Do **not** union `affiliate` edges into the `group_member` components. Connected
components over both edge types together swallow the health-system and
university sectors into one giant blob.

Schedule C (§501(h) affiliated-group rosters, TY2013) is not a third structure:

```
Schedule C undirected pairs        430   (self-loops removed)
already present as Schedule R      394   = 91.6%
```

It is reciprocal — every electing member reports the whole group, so 78 of 123
filers list their own EIN — which makes it an undirected edge list of the same
shape as Schedule R. File as `relation='affiliate'`,
`evidence='schedule_c_part_ii_a'`. It is a lobbying-control concept under §4911,
so it must stay out of the `group_id` components.

## 3. Why `group_id` earns its place

### Reference side

Exact `name_key` collisions over 3.69M BMF legal names:

```
ambiguous clusters (>1 EIN)   147,020   =  4.9% of keys
EINs in an ambiguous cluster 1,147,005  = 31.1% of EINs
```

| cluster class | clusters | % clusters | % of ambiguous EINs |
|---|---:|---:|---:|
| all members share ONE GEN | 5,037 | 3.4% | 1.7% |
| one GEN + members without one | 15,945 | 10.8% | **43.2%** |
| members span MULTIPLE GENs | 4,494 | 3.1% | **25.2%** |
| no member has a GEN | 121,544 | 82.7% | 29.9% |

Group structure explains 17% of ambiguous *clusters* but 70% of ambiguous
*EINs* — ordinary collisions come in pairs, group collisions in thousands.

```
EINs WITHOUT a GEN: 19.9% sit in an ambiguous cluster
EINs WITH    a GEN: 83.7% sit in an ambiguous cluster
```

### Query side — the pinned benchmark

Against `benchmark-1k-augmented.rds`, rerun with `pairs` retained and
reproducing YES 3015 / MAYBE 1041 / NO 737 exactly. 674,511 candidate pairs;
19.1% of candidate rows are group subordinates.

**Reference-side prevalence does not transfer to the query side.** Group cases
are 13.0% of MAYBE against 5.8% of YES — a 2.2× enrichment, not a majority.

Restricting to close candidates (within 0.02 of top) and to genuinely ambiguous
sets (≥2 close candidates):

| | YES | MAYBE | NO |
|---|---:|---:|---:|
| ≥2 close candidates | 0 | 513 | 451 |
| — containing a group cluster | — | **63 (12.3%)** | 56 (12.4%) |
| group cluster anywhere in close set | **0 of 3,015** | 63 | 56 |

**A group cluster in the close set never co-occurs with YES.** It appears at the
same rate in NO as in MAYBE, so it marks *not-YES*, not *MAYBE specifically*.

Collapsing each group to one node, among the 63:

```
collapse to a SINGLE node    27  (42.9%)   fully resolvable at group grain
collapse to <=2 nodes        41  (65.1%)
close candidates 10,451 -> 3,497           66.5% removed
```

The other 450 ambiguous MAYBEs: **zero** candidates removed. Group structure is
inert outside the 63.

Blowups shrink but do not resolve — `DUCKS UNLIMITED` 5,363→740 (4,624 in one
group), `AARP` 1,926→1,124, `SEATTLE CHILDRENS HOSPITAL` 579→339. The residual
is loose blocking, not group structure.

### It is not redundant with what pfmatch already does

```
                       top candidate is a group member
affiliate_suffix veto   FALSE   TRUE
                FALSE    4263    360
                TRUE      162      8      Jaccard = 0.015
```

The lexical veto fires 170 times; **8** are actual subordinates. The heuristic
and the structural fact are nearly disjoint sets.

### Scale

The 54 distinct `name_key`s behind the 63 cases account for **789 of 100,000
grants (0.79%)** and **0.90% of $4.06B** in `100k_grants.csv`. Low single-digit
percent, not tens. Lower bound — the 100k contains group names absent from the
1k sample.

## 4. Why `semantic_group_id` is rejected

Semantic cohesion is not a property of the group. It is a property of the name
variant selected, which makes it a function of `(variant_class, source,
normalize_signature)` — i.e. of the **spec**. Storing it bakes a spec into the
database and would need invalidation on every normalizer bump (§9).

From `affiliate_listing_2013.csv` against BMF legal names, 1,068 of 1,070
subordinates matched:

```
BMF name_key == e-file self-reported name_key    265  (24.8%)
BMF name_key != e-file self-reported name_key    803  (75.2%)
```

The BMF assigns subordinates the **parent's** name:

| EIN | e-file self-reported | BMF legal |
|---|---|---|
| 20-4193243 | Einstein Medical Center Montgomery | ALBERT EINSTEIN HEALTHCARE NETWORK |
| 23-1352200 | Belmont Center For Comprehensive Tr | ALBERT EINSTEIN HEALTHCARE NETWORK |
| 23-1396794 | Albert Einstein Medical Center | ALBERT EINSTEIN HEALTHCARE NETWORK |
| 23-2664784 | Einstein Practice Plan Inc | ALBERT EINSTEIN HEALTHCARE NETWORK |
| 23-2760086 | Einstein Community Health Associate | ALBERT EINSTEIN HEALTHCARE NETWORK |

Across the 70 group returns with ≥3 listed affiliates:

| | BMF names | e-file names |
|---|---:|---:|
| median distinct names / members | 0.134 | 1.000 |
| groups where all members share one name | 70.0% | 12.9% |

Same EINs, same group, opposite semantic clustering.

It is also either redundant or destructive depending on where it is applied:

| clusters with ≥3 members | group return | related entity |
|---|---:|---:|
| modal_share (median) | **0.905** | **0.333** |
| all members share one name | 22.1% | 1.4% |
| **no two members share a name** | 9.3% | **78.1%** |

Inside group returns the structural cluster already *is* the semantic cluster.
Inside related entities a semantic filter would shatter exactly the networks
worth keeping — `GIVERS TRUST INC` and `CHFSS` share no tokens with `NATIONAL
CHRISTIAN FOUNDATION`, so only the disclosure can link them.

**What to do instead:** compute `same_structural_group(A,B) AND name_similar(A,B)`
as a pairwise predicate at match time. Zero storage, correct under any spec, and
the close-candidate set already satisfies the second conjunct by construction.

### The archetype taxonomy does work

Derivable post-hoc from `ein_relation` + `name` + `address`:

| archetype | clusters | med members | modal_share | name_div | med states |
|---|---:|---:|---:|---:|---:|
| A. federated (chapters) | 2,133 | 27 | 0.97 | 0.09 | 2 |
| B. group ruling, heterogeneous names | 1,125 | 13 | 0.33 | 0.75 | 3 |
| C. unified complex (co-located) | 8,130 | 3 | 0.33 | 1.00 | 1 |
| D. dispersed related-entity network | 558 | 7 | 0.25 | 1.00 | 3 |

Two features do the work — name homogeneity and geographic dispersion — crossed
with which relation type produced the cluster.

## 5. The e-file affiliate names are the highest-value item here

Held-out retrieval, 804 queries across 58 groups: hold out each affiliate's
self-reported name, build the group signature from the *other* members, score
IDF-weighted token overlap.

| index | rank 1 | rank ≤10 | found at all |
|---|---:|---:|---:|
| group union, BMF + sibling e-file names | 46.9% | 85.2% | 89.1% |
| group union, BMF names only | 36.3% | 78.0% | 81.6% |
| exact EIN, BMF legal names | 2.6% | 9.7% | 61.3% |

The e-file tokens are **3,687 of 1,985,440 signature postings — 0.19% of the
index** — and carry 10.6 of the 46.9 points. That is a finding about data
acquisition, not about blocking. Ingest them as `observed` variants on the
subordinates' own EINs, all years, regardless of what else gets built.

The exact-EIN column collapses because subordinates share the parent's name, so
name-only scoring produces large tie sets that cannot be broken. That is the
same under-determination the benchmark shows as margin-zero ties.

Note the asymmetry that makes group grain genuinely non-redundant: a sibling's
name can only ever identify the *group*. At EIN grain a sibling's name pointing
at the sibling's EIN is a **false** match.

## 6. Why the union index is rejected

### It cannot be gated

Scoring 4,000 randomly sampled non-group EINs against the group index:

```
84.9% of NON-group orgs hit some group signature
keep 90% of true members -> 89.0% of non-members also pass
keep 75% of true members -> 61.3% of non-members also pass
keep 50% of true members -> 30.1% of non-members also pass
```

Best-score medians: true members 15.90, non-members 12.65. No usable threshold
exists, so the group path can never let a query skip the full sweep — and 88% of
the universe is not in a group at all.

### It has a size bias

Among wrong rank-1 hits the wrong group is larger than the true group **62.6%**
of the time (median 1,380 vs 545 members). `sqrt(sig_len)` normalisation made
rank-1 *worse* (24.9% vs 29.0%), so it is not a one-line fix.

### End to end it is marginal

Unconditional accuracy over all 804 queries — scoring is IDF-sum plus an address
bonus (zip5 = 6, city+state = 4, state = 1), **not** npmatch's scorer, so read
the columns relatively and not as npmatch performance:

| config | rank 1 | rank ≤5 | recall | med candidates |
|---|---:|---:|---:|---:|
| A. full BMF sweep (baseline) | 15.5% | 26.4% | 61.3% | 4,601 |
| B. group path only, K=1 cap=2,000 | 11.7% | 17.5% | 27.7% | **69** |
| B. group path only, K=3 cap=2,000 | 16.0% | 26.1% | 38.3% | 635 |
| **C. merged, K=1 cap=2,000** | **16.5%** | 27.2% | 61.6% | 4,890 |
| C. merged, K=1 uncapped | 15.7% | 26.5% | 62.7% | 8,977 |

The size cap is real and large — uncapped expansion costs 21,357 candidates at
the median, capped costs 69 — and the group path alone at K=3/cap=2,000 matches
the full sweep's rank-1 (16.0% vs 15.5%) on **1/7th the candidates**. But its
recall is 38.3% against 61.3%, so it cannot replace the sweep, and merging buys
**+1.0 point of rank-1 for +6% candidates**. Not worth a new table.

> **Correction.** An earlier pass reported rank-1 up to 44.3% for the capped
> variant and concluded the cap "reverses" the negative verdict. That metric
> conditioned on the truth being retrieved (`na.rm=TRUE` silently dropped
> queries where it was not), which flatters a low-recall path exactly like this
> one. A separate earlier pass used `ties.method="min"`, which awards rank 1 to
> every member of a tie and inflated group-union rank-1 from 46.9% to 69.4% and
> exact-EIN from 2.6% to 47.5%. **Rank metrics on this task must be
> unconditional and must break ties randomly.**

### Address unions do not block

| block | correct group found | groups returned (median) |
|---|---:|---:|
| city + state | 74.4% | 154 |
| zip5 | 72.3% | 59 |
| zip5 + city | 70.9% | 56 |

Median **1.64 distinct cities per member** — orgs carry multiple address
variants — and only 47 of 3,258 groups sit in a single city. Address is a
scoring feature, not an index.

## 7. Open

- **Held-out set is thin.** 804 queries, 58 groups, all TY2013 — and only 99 of
  483 group filers itemise members at all. Extend across 2009–2013 before
  trusting the §5 figures to more than one significant figure.
- **Address is doing nearly all the work** in §6 (name-only 2.0% → +address
  27.2% on the conditional metric). Any future group work should be measured
  against a name+address baseline, never name-only.
- **Archetype labels are unvalidated.** The four classes separate on the
  features that define them; nobody has checked them against ground truth.
