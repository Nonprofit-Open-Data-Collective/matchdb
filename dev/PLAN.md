# matchdb — development plan

**Status: proposal, 2026-08-21. No code written yet.**

This is the design document for `matchdb`, written before implementation so the
boundaries can be argued about while they are still cheap to move. It was
produced from an audit of the working `npmatch` and `pfmatch` code, and every
performance claim in it is measured, not estimated.

---

## 0. Orientation — read this first if you are starting cold

**What matchdb is.** A build system and distribution layer for a *disambiguation
database*: the universe of known (EIN → name, EIN → address) observations from
every source of truth we can get, with provenance, deduplicated, normalized, and
compiled on demand into the reference frame that `npmatch` matches against.

**What it is not.** It is not a matching engine. Blocking, comparison, veto,
scoring, and tiering all live in `npmatch` and stay there. matchdb's only
deliverable is *a well-described reference*.

**Sibling repositories** (all under `Nonprofit-Open-Data-Collective`, cloned
side by side locally):

| repo | role |
|---|---|
| `npmatch` | generic record-linkage engine. Normalization, blocking, scoring, vetoes, tiering. Depends on neither of the others. |
| `pfmatch` | 990-PF grant-recipient matching. The first consumer, and where all the evidence below was gathered. |
| `matchdb` | **this repo.** The reference database. |
| `ef2` | IRS 990 e-file processing. Not a dependency, but its S3/DuckDB pattern is the model for §7. |

**Evidence base.** The findings cited here live in `pfmatch/dev/`. Worth reading
before starting:

* `MATCHDB-PLAN.md` — the parent of this document
* `REF-PERFORMANCE.md` — measured cascade cost by reference size
* `PROMOTION-FLOOR-FINDINGS.md` — why the IDF gate was disabled
* `SCHEDI-ALIAS-FINDINGS.md`, `AUDIT-FINDINGS.md` — what the alias source buys
* `IDF-ATOMIZE.log`, `REFBUILD-COST.log` — the benchmarks behind §6c

---

## 1. Verdict

**Build it, at about two-thirds of the originally proposed scope.**

The core design — long attribute tables with provenance, selected by layer and
variant class — is right, and is *already half-implemented by accident* in
pfmatch. Three separate places invented pieces of it, in three formats, none
composable. That is the strongest argument for doing this, and it also means
most of the work is extraction rather than invention.

What to cut or defer is in §10. The hazards that could make this worse than the
status quo are §6b (a live defect), §7 (distribution), §8 (row blowup) and §9
(normalizer drift). All four must be designed in, not retrofitted.

---

## 2. What is already true

Facts the design has to respect. All verified in the current code.

**The row-per-variant pattern already exists.** `pfmatch/R/schedi.R:239`
(`pf_bmf_augment()`) takes the Schedule I alias table, clones each EIN's BMF row,
overwrites name and address with the observed alias, and `rbind`s it on with a
`row_source` column. The matching engine already tolerates many rows per EIN;
selection resolves on `.ein`, so duplicates collapse. **The long tables proposed
below are not a new architecture — they formalize the one hack that already
works.** That materially lowers the risk of this whole plan.

**The canonical contract is narrow and wide-format.** `npmatch/R/config.R:10`
(`np_fields`) is one `name`, one `dba`, one `division`, one address block, plus
`.ein` and `active`. Everything downstream reads those columns. A relational DB
cannot be handed to the matcher directly — it must be **compiled** into that
wide frame. That compile step is the crux of the design (§6).

**A file-shaped data-asset layer already exists in npmatch.**
`npmatch/R/assets.R` and `fetch.R` give `np_data_root()`, the
`raw/ normalized/ results/` tiers, `MANIFEST.csv` with md5 and row counts,
`np_fetch()`, and `np_source_urls()` pointing at
`nccsdata.s3.../crosswalks/npmatch`. Perhaps 60% of the plumbing exists. What it
lacks is any notion of a *table*, a *variant*, or a *spec*.

**Provenance is currently encoded in filenames.** `pfmatch/data-dev/` holds
`BMF-AUGMENTED-unified.csv`, `BMF-AUGMENTED-unified-fixed.csv`,
`BMF-AUGMENTED-bmf_unified_geocoded_2026-08-20.csv`, `REF-active.rds`,
`REF-unified.rds`, `REF-augmented.rds`, `BMF-REF-AUG-2026-08-20.rds`. Seven
near-synonymous artifacts distinguished by a convention that exists in one
person's head. This is the problem, already realized.

**Cost is measured and headroom is finite.** From `pfmatch/dev/REF-PERFORMANCE.md`:
1.92M reference rows → 128 s per 1,000 identities; 3.89M rows → 226 s. Sublinear
(1.77× time for 2.02× rows), but the full 12.5M-grant file at the augmented
reference is already **66–81 hours on 12 shards**. Reference size is the dominant
cost term in the project. Any design that multiplies variants without a budget
makes the full run infeasible. See §8.

---

## 3. Three axes

"Tranche", "layer", "version", "variant" and "feature" get used
interchangeably. They are three different things and conflating them is what
makes the current process hard to reason about.

| axis | question | lives on | user-selected? |
|---|---|---|---|
| **Layer** | which EINs exist at all | entity table | yes |
| **Variant class** | which observed strings for that EIN | attribute tables | yes |
| **Derived column** | which normalization of that string | columns on an attribute row | no — always built |

**Layers** are a property of the *entity*: active BMF, inactive BMF, EINs seen on
990 filings but in no BMF, 527 organizations. Choosing layers changes *who can be
matched*.

**Variant classes** are a property of the *attribute row*: BMF legal name, BMF
DBA, Schedule I observed alias, in-care-of name, former name. Choosing them
changes *how many ways an entity can be spelled*, and each one added multiplies
reference rows.

**Derived columns** are `np_normalize()`'s output — `name_key`, `name_full`,
`name_gen`, `name_form`, `street_key`, `zip3`, `zip9`. Pure functions of the raw
string. Never selected; precomputed once and shipped. This is where most of the
wall-clock saving lives (§6c).

---

## 4. Schema

Five core tables plus two relations. All keyed on a 9-digit EIN.

### `entity` — one row per EIN, the layer axis

```
ein                 char(9)   PK
layer               enum      bmf_active | bmf_inactive | filer_only | irs527
active              bool      currently in the active BMF
first_seen          date
last_seen           date
subsection, ntee_code_clean, nteev2, foundation_code, affiliation_code,
group_exemption_number, ruling_date, assets, revenue, form_990, ...
```

`layer` is provenance (which tranche this EIN came from); `active` is status.
Keeping them apart is what lets an update flip status without rewriting
provenance.

### `name` — many rows per EIN, the variant axis

```
name_id             bigint    PK
ein                 char(9)   FK
name_raw            text      as written by the source
variant_class       enum      legal | dba | division | in_care_of |
                              observed | former
source              enum      bmf | schedi | efile990 | irs527
source_vintage      text      "bmf-2026-01", "schedi-2009-2023"
n_obs               int       times observed (NULL for BMF)
n_corroborators     int       distinct filers who wrote it (Schedule I trust)
first_year, last_year
-- derived, computed once at build:
name_key, name_full, name_gen, name_gen_rank, name_nums,
name_ord, name_dir, name_form, name_acro, name_pre,
name_tokens         text      cleaned, deduped token set (see §6c)
```

`variant_class` × `source` is the selection axis. `n_corroborators` is already
computed in `pfmatch/dev/build-schedi-db.R` as `n_filers` and is the right trust
signal to keep first-class and filterable — the `min_filers` knob currently baked
into a build script becomes a spec parameter.

**Note there is no `is_primary` column.** See §7d: primacy is derived at compile
time from `source_vintage` ordering, which is what keeps the database genuinely
append-only.

### `address` — many rows per EIN

```
address_id          bigint    PK
ein                 char(9)   FK
name_id             bigint    NULL — the pairing link, see §8
street_raw, unit_raw, city_raw, state, zip5, zip_plus4
variant_class       enum      mailing | principal | observed | historical
source, source_vintage, n_obs, n_corroborators, first_year, last_year
-- derived:
street_key, street_num, street_name, street_type, street_unit,
is_po_box, city, zip3, zip9, lat, lon, county, cbsa
```

The `name_id` foreign key is not decoration. It is what stops the cross-product
blowup in §8.

### `orgtext` — mission and program text

```
ein, tax_year, text_kind (mission | program_1..n | ntee_desc), text, source
```

EIN-keyed, deliberately outside the name/address selection logic. See §10.

### `ein_relation` — affiliate and dyad structure

```
ein_a, ein_b, relation (group_parent | group_member | affiliate |
                        dyad_substitutable | successor), evidence, confidence
```

Where affiliates go. Not the name table. See §10.

### `source_vintage` — the audit table

```
vintage_id, source, url, fetched, md5, row_count, rows_added, build_note,
npmatch_version, normalize_signature
```

One row per ingest. This is `np_manifest()` promoted from a CSV of files to a
table of loads, and it is what makes any compiled reference explainable six
months later. The last two columns are the §9 drift guard.

---

## 5. The spec

The user-facing object: a small, serializable, hashable description of a
reference.

```r
spec <- md_spec(
  layers     = c("bmf_active", "bmf_inactive"),
  names      = c("legal", "dba", "observed"),
  addresses  = c("mailing", "observed"),
  filters    = list(observed_min_corroborators = 2, drop_before_year = 2010),
  max_names_per_ein     = 3,
  max_addresses_per_ein = 2,
  vintage    = "2026-08"
)
```

Everything in "let the user specify layers and versions" lands here. **The spec
hash is the cache key.** Two runs with the same hash are the same reference,
verifiably, on any machine.

---

## 6. The compile step

`md_compile(spec)` turns the database into the wide `np_reference` frame the
cascade wants: one row per (EIN × selected name × paired address), derived
columns present, `.ein` and `active` set.

### 6a. Corpus statistics are properties of the spec, not the database

`pfmatch/R/match.R:188` computes two tables *over the reference it just built*:

* `np_name_freq()` — `table(name_key)`, a **raw count** of records sharing each
  exact normalized name.
* `np_token_idf()` — `log(N / df)` per token.

**Only the first currently moves a score.** In `npmatch/R/score.R:96` the
distinctive-name promotion fires on `nf <= distinct_name_maxfreq`, default 3. The
IDF gate (`distinct_name_min_idf`) exists beside it but ships at **0, disabled** —
`pfmatch/dev/PROMOTION-FLOOR-FINDINGS.md:216` retired it because
`distinct_name_main_only` fixed the same errors more directly. `name_idf` is
computed and carried, but only annotates the review queue.

The consequence comes from `name_freq` being a **count, not a rate**. Reference
rows only ever get added, so counts rise monotonically, so the promoted set
shrinks monotonically as the reference grows. A legal name shared by 2 records in
the active BMF may be shared by 4 once inactive EINs and Schedule I aliases are
in — same name, same query, no longer promoted. **Growing the reference is not a
pure recall gain; it silently tightens an auto-acceptance gate.** The measured
"+43 YES" for the augmented reference is a *net* of aliases won and promotions
lost, and the two have never been separated. Worth separating early.

So the compiled bundle must carry its own `name_freq`, `token_idf` and
`ref_index`, stamped with the spec hash, and `np_cascade()` should refuse a
bundle whose stamp does not match the reference it was handed.

### 6b. `variant_class` should gate the promotion — a live defect

The promotion's stated justification (`npmatch/R/score.R:69`) is "this exact
*legal* name is rare in the reference." `distinct_name_main_only` enforces it by
requiring `name_ver_y == "MAIN"`. But `pf_bmf_augment()` writes the Schedule I
alias *into* `org_name_join` — the column `np_map_bmf()` maps to `name`. A cloned
alias row therefore reads as MAIN, and a rare observed alias can be auto-accepted
under a rule written to trust IRS legal names only. `main_only` cannot see the
difference because there is nothing in the row to see.

A first-class `variant_class` fixes it: gate on `variant_class == "legal"` and
the rule means what its comment says.

**The provenance does not currently survive to the matcher at all.**
`pf_bmf_augment()` writes `row_source`, `alias_n_filers` and `alias_last_year`
onto the augmented BMF, but `.np_canonicalize()` (`npmatch/R/canonicalize.R:204`)
subsets to exactly `np_fields`, and none of those three appear anywhere in
npmatch. They are dropped before blocking. So the situation is not merely that
`main_only` ignores variant provenance — **there is no variant provenance in the
frame to ignore**, and the effect cannot be measured without a change.

The prerequisite is therefore small and belongs in **npmatch, not matchdb**: add
`variant_class` (and optionally `variant_n_corroborators`) to `np_fields`,
defaulting to `NA` so every existing caller is unaffected. That single change
makes the question measurable, and it is the same column matchdb would populate
later. Do it first; see Phase 0.

### 6c. What recompilation actually costs — measured

Active BMF, 1,924,822 rows (`pfmatch/dev/probe-refbuild-cost.R`):

| component | seconds | share | recompiles per spec? |
|---|---:|---:|---|
| `np_normalize` | 269.7 | 66% | **no** — per-row, precompute as columns |
| `np_ref_index` | 87.8 | 22% | yes, decomposable but fiddly |
| `np_name_freq` | 27.5 | 7% | yes — corpus statistic |
| `np_token_idf` | 22.8 | 6% | yes — corpus statistic |
| **full rebuild** | **407.8** | | |
| *(readRDS the cached bundle)* | *50.7* | | *monolithic, 1.43 GB* |

Two thirds is `np_normalize`, and it needs no clever math: it is a pure per-row
function, so storing its output as columns drops it to **zero**. That is the
single biggest reason to build the schema as §4 describes.

The corpus statistics are the only parts that genuinely depend on which rows a
spec selects — and both are **additive counts**, so both decompose exactly.
Document frequency for a union of cells is the sum of the cells' document
frequencies. Store, per cell, a dense integer vector aligned to a global token
vocabulary; recombination is a `rowSums` plus a `log`
(`pfmatch/dev/probe-idf-atomize.R`):

| approach | per-spec cost |
|---|---:|
| recompute live (today) | 41.1 s |
| tokens stored as a pre-cleaned string | 11.6 s |
| **per-cell df vectors, recombine** | **0.03 s** |

Verified identical to direct computation (191,181 tokens, max abs diff < 1e-9).
The matrix is 8.3 MB for 8 cells.

Note *why* the middle row only buys 3.5×: `name_key` **is already** a
space-delimited token string, and splitting it costs 1.95 s of the 41. The 82% is
`unique()` plus the stopword and min-length filter. The gain comes from
pre-deduplicating and pre-filtering, not pre-splitting — so the stored
`name_tokens` column must be the *cleaned* token set or it buys nothing.

Exactness holds only for specs that are **unions of precomputed cells**. A
row-level filter such as `observed_min_corroborators = 2` breaks it — so
pre-bucket by the corroborator bands `build-schedi-db.R` already reports
(1, 2–4, 5–19, 20+) and make such filters snap to band edges. See §7b.

`np_ref_index` (22%) decomposes on the same principle — it is a `(row, token)`
posting list plus doc-frequency counts — but concatenating per-cell posting lists
requires remapping row offsets. Real work; defer it.

**The honest scope of this win.** Against production throughput it is nothing:
408 s is 0.15% of a 66-hour sharded run. Precomputation does **not** make matching
faster and must not be sold as if it does. What it changes is whether spec
selection is *usable*: roughly 7 minutes per spec versus about 2 seconds. At 7
minutes nobody explores and everyone reuses whatever reference is already cached
— which is exactly the ad-hoc behaviour §2 documents. At 2 seconds, tuning the
reference to the task becomes something people actually do.

---

## 7. Distribution and workflow

The question this section answers: given a global `MATCHDB.duckdb` on S3, what
should `pfmatch` and `npmatch` actually *do*?

### 7a. Remote attach is right for metadata, wrong for compilation

`ef2` proves the remote pattern works — `R/99_utils_s3.R` does
`ATTACH 's3://…duckdb' AS src (READ_ONLY)` over httpfs and queries without
downloading. But look at *which* queries: `SELECT DISTINCT url FROM KEYS`, an
index check. Those are **selective**, and DuckDB's httpfs layer serves them with
HTTP range requests that touch a few pages.

Compiling a reference is the opposite: a near-full scan of the name and address
tables — every EIN, every selected variant, ~15 derived text columns each. Over
httpfs that is "download the whole thing, slowly, in pieces, uncached, every
session." Bulk transfer beats ranged transfer of the same bytes, and a local file
is reusable.

So: **remote attach for exploration and provenance questions; bulk download for
anything that compiles.** Not either/or.

### 7b. Three artifact tiers

The key decision is that **the thing most users download is not the DuckDB.**

**Tier 1 — compiled references. The default path, ~95% of use.**
Pre-built per *named* spec, published as **parquet**, with the sidecar
`name_freq` / `token_idf` / `ref_index` stamped with the spec hash (§6a). This is
exactly the "tidy BMF, one row per name/address combination" intuition. Ship a
small set:

| name | layers | names | addresses |
|---|---|---|---|
| `active-legal` | active | legal, dba | mailing |
| `unified-legal` | active + inactive | legal, dba | mailing |
| `unified-observed` | active + inactive | legal, dba, observed (≥2 corroborators) | mailing, observed |

`pf_reference()` becomes `md_reference("unified-observed")` — one bulk GET,
cached locally by spec hash, **zero compile cost**. Parquet rather than DuckDB
here because it is a single flat table read once and fully scanned: columnar
selection, ~4–6× compression on this kind of text, streams, and both `arrow` and
DuckDB read it natively. A DuckDB file for one flat table adds nothing.

**Tier 2 — atom tables. The custom-spec path.**
The `entity` / `name` / `address` tables as **partitioned parquet**, partitioned
on the cell dimensions: `layer` × `variant_class` × corroborator band. A custom
spec then becomes a partition-pruned read — DuckDB reads only the partitions the
spec names, and here remote querying genuinely works, because pruning makes it
selective again. Compile locally in seconds (§6c).

> **Make the physical partitioning identical to the statistical cell
> decomposition.** The partitions in Tier 2 and the per-cell `df` vectors in §6c
> must be the same cells. One concept, two payoffs: partition pruning for I/O,
> vector summation for statistics. If they ever diverge you get statistics
> describing a different row set than the one loaded — a silent, near-undebuggable
> class of error.

**Tier 3 — `MATCHDB.duckdb`. Build and maintenance.**
The full relational database with provenance, `source_vintage`, `ein_relation`.
This is the source of truth and the ingest target, but **not the consumption path
for matching**. You attach it to answer "why is this name in here?" and to run
updates. Tiers 1 and 2 are generated *from* it by a publish step.

### 7c. The N-best gate

Yes — and it belongs in compile, as a spec parameter, defaulting to something
sensible in the published tiers. Two requirements:

1. **"Best" needs a defined total order**, not a judgment call. Proposed:
   `variant_class` rank (legal first), then `n_corroborators DESC`,
   `last_year DESC`, `n_obs DESC`, `name_id ASC` as a deterministic tiebreak.
   Determinism matters — the spec hash is worthless if the same spec can yield
   different rows.
2. **Cap per class, not globally.** `max_names_per_ein = 3` applied globally would
   let three observed aliases displace the legal name. Express it as
   "all `legal` + top 3 `observed`".

Do not guess the N. Sweep it on the pfmatch 1k benchmark and pick from the
recall-vs-rows curve; `dev/REF-PERFORMANCE.md` already has the harness.

### 7d. Updates — and the refinement that makes them safe

The ef2 shape is right: download, ingest, upload. Four adjustments.

**Make the database genuinely append-only by deriving status, not storing it.**
"Updates are just new rows" holds for names and addresses but breaks on status:
`active`, and which name is currently primary, are *flips on existing rows*. If
those are `UPDATE`s then the append-only reasoning fails and every incremental
argument with it. Instead **do not store primacy at all** — derive it at compile
time as "the `legal` name from the newest `source_vintage` for this EIN". Then
appending a new BMF vintage automatically re-primes every name, with no update,
and history stays intact. `entity.active` is the one genuinely mutable field;
recompute it wholesale per vintage from the active EIN set, which is a rewrite of
one narrow column rather than a diff.

**Never overwrite a published object.** Put the vintage in the key —
`s3://…/matchdb/v2026-08/MATCHDB.duckdb` — and publish a tiny `latest.json` at a
stable URL naming the current vintage. Packages default to `latest`, can pin to a
vintage, and a bad build can never destroy a good one. Rollback is editing a
pointer.

**Accept whole-file re-upload; do not shard.** ef2 shards by tax year because it
has a natural one. matchdb does not, and sharding a relational database by source
breaks exactly the cross-source queries it exists to answer. A multi-GB quarterly
upload is fine.

**Write down that there is no concurrency control.** Download-append-upload is
last-writer-wins. With one maintainer that is acceptable; it should be a stated
assumption rather than an accident. Versioned keys make a collision recoverable.

### 7e. The resulting call sequence

```r
# default: a published spec, no compile
ref <- md_reference("unified-observed")            # cached by spec hash

# custom: partition-pruned read + local compile (~seconds)
ref <- md_compile(md_spec(layers = c("bmf_active"),
                          names  = c("legal", "observed"),
                          filters = list(observed_min_corroborators = 5)))

# provenance: remote, selective, no download
md_explain(ein = "133039601")     # every name/address on file, with source

# maintenance
md_ingest_bmf(vintage = "2026-10")     # against a local MATCHDB.duckdb
md_publish(vintage = "2026-10")        # regenerate tiers 1+2, upload, bump latest
```

---

## 8. Expansion control

Where this can go wrong quantitatively.

If an EIN has *k* selected names and *m* selected addresses, the naive compile
emits *k × m* rows. At 1.9M EINs with three of each that is up to 17M rows against
today's 3.9M. Extrapolating `REF-PERFORMANCE.md`, the full run would go from
66–81 hours on 12 shards to roughly 200 hours — the difference between a weekend
and a fortnight.

Three guards, all cheap, all mandatory:

**The pairing rule.** A Schedule I alias was observed *together with* an address,
and that pairing is real information already captured — the alias table groups on
`(ein, name_norm, city, state, zip5)`. So an observed name pairs with *its own*
observed address via `address.name_id`; only BMF-sourced names cross with
BMF-sourced addresses. Emission becomes roughly *k + m* rather than *k × m*.
`pf_bmf_augment(address = "alias")` already does this — the schema just has to
preserve the link so the compiler can honour it.

**A row budget.** `md_compile()` takes `max_rows`, estimates emission before
materializing, and errors over budget naming the responsible variant class —
rather than silently producing a reference that costs four times what was planned.

**Report the shape.** Every compile prints rows per source and the rows-per-EIN
distribution. `build-augmented-bmf.R` already prints `aug[, .N, by = row_source]`.
Keep it, make it universal.

---

## 9. Package boundary and the drift hazard

```
matchdb  --Imports-->  npmatch        (np_normalize, np_token_idf, np_initials)
pfmatch  --Imports-->  npmatch, matchdb
npmatch                                (depends on neither; stays a pure library)
```

Reasons this is the right cut: matchdb needs DuckDB, DBI, arrow and S3 tooling
while npmatch imports only data.table/stringi/stringr and should stay that light;
npmatch versions on code changes while the database versions on IRS data
vintages; there are already two consumers and the sibling repos suggest more; and
it is a *data product*, not a library.

### The hazard: normalizer drift

matchdb precomputes `name_key`, `street_key` and friends by calling
`np_normalize()`. The **query** side is normalized at run time by whatever npmatch
is installed. If npmatch's normalizer changes after an artifact is built, the two
sides are normalized differently and **recall silently degrades** — no error, no
warning, and a symptom that looks like a data problem.

Not hypothetical: `.np_strip_lead_the()` was added to `name_key` for a real false
negative found in labelling, and `.np_abbrev` is a token table that will keep
growing.

Required from the first commit:

1. npmatch exports `np_normalize_signature()` — a hash over the normalizer's rule
   tables (`.np_abbrev`, suffix list, stopwords) and function bodies.
2. matchdb stamps it, plus the npmatch version, into every artifact and into
   `source_vintage`.
3. `md_reference()` / `md_compile()` compare the stamp to the installed npmatch
   and **error** (not warn), with the remedy: rebuild, or pin npmatch.

Without this, the caching everything here is built on becomes a correctness
liability rather than a speedup.

---

## 10. What is deliberately out of scope

**Mission and program text: in the bundle, out of the variant machinery.**
`pf_purpose_tiebreak()` and `pf_attach_missions()` consume mission text *after* a
candidate list exists, to break ties. It is adjudication input, not
candidate-generation input. Keep it as a plain EIN-keyed `orgtext` table joined on
demand. Putting it in the name/address selection model invites someone to block on
it, which at 1.9M EINs × paragraph-length strings would be a disaster.

**Per-source incremental differencing: defer.** Appends are easy; deciding "is
this the same address written differently, or a new one?" is where the bugs live,
and a full rebuild in DuckDB is minutes. Build `md_ingest_*()` as **idempotent
full loads keyed on `source_vintage`**. Combined with §7d's derived primacy, this
removes a whole class of drift bug at negligible cost.

**Affiliates are not DBAs.** Group-exemption subordinates and affiliate chapters
are *distinct EINs with near-identical names* — precisely the condition that
produces false matches. Registering "BOYS AND GIRLS CLUB OF SPRINGFIELD" as an
alias of the national EIN would make disambiguation worse. Affiliate structure
belongs in `ein_relation`, consumed at *selection* time by machinery that already
exists in `pfmatch/R/dyads.R` and `affiliation.R`. matchdb's job is to record the
relation with provenance; pfmatch decides what to do with it.

The narrow exception: where a subordinate genuinely files under a brand name
distinct from its legal name, that is an `observed` name on the subordinate's own
EIN, sourced from Schedule I like any other — already handled by the normal path.

**Generated variants stay columns, not rows.** Acronyms and prefixes are pure
functions of `name_key`. `pf_add_recovery_keys()` already computes them as
columns (`name_acro`, `name_pre`), which is strictly cheaper than a new row and
blocks just as well. Reserve `variant_class = 'observed'` for acronyms actually
seen in the wild — different information.

---

## 11. Phasing

Build order is **extraction, not fresh design**: every stage moves code that
already works and is already benchmarked.

**Phase 0 — vocabulary, and make §6b measurable.** Freeze the `layer` and
`variant_class` enumerations (§3) — cheap now, expensive later.

Then, in **npmatch**: add `variant_class` to `np_fields`, defaulting to `NA`.
Then, in **pfmatch**: have `pf_bmf_augment()` populate it (`"legal"` for BMF
rows, `"observed"` for alias rows) and map it through `np_map_bmf()`. Then count,
on the existing 1k augmented benchmark, how many YES verdicts came from the
distinctive-name promotion firing on an `observed` row.

That count decides what happens next, and nothing before it is worth arguing
about:

* **0–2** — close §6b as a non-issue with a note; the guard's blind spot is real
  but empty.
* **10+** — run the full A/B gating promotion on `variant_class == "legal"`, and
  treat the measured "+43 YES" for the augmented reference as unverified until
  it is decomposed.

This is a few hours of work against artifacts that already exist, and it is
worth doing whether or not matchdb is ever built.

**Phase 1 — entity + name + address, BMF only.** `md_ingest_bmf()` loads active
and unified. `md_compile()` emits the wide frame.
**Success criterion: the spec `layers = bmf_active, names = legal+dba,
addresses = mailing` reproduces today's `REF-active.rds` row-for-row, and
pfmatch's `PF_SET=1k` benchmark is byte-identical.** If that holds, the
abstraction is free. If it cannot, stop and reconsider — it would mean the
abstraction is changing behaviour, which is the failure mode this plan exists to
avoid.

**Phase 2 — Schedule I as `observed`.** Move `pfmatch/dev/build-schedi-db.R` and
`pf_bmf_augment()` behind `md_ingest_schedi()`. **Success criterion: the spec
adding `observed` at `min_corroborators = 2` reproduces
`BMF-AUGMENTED-unified.csv`, and the 1k benchmark reproduces the measured +43 YES
/ +10 MAYBE.** The row-clone hack is then retired and its behaviour is a
selectable spec.

**Phase 3 — publication.** Per-cell `df` vectors (§6c), spec-stamped bundles
(§6a, §9), partitioned parquet (§7b), the three named tiers, `latest.json`.
Repoint `pf_reference()` at `md_reference()` with the local path as fallback.
This is the phase that pays back.

**Phase 4 — remaining layers.** `filer_only` EINs, 527s, `ein_relation`,
`orgtext`. Each is one ingest function against a proven schema.

Phases 1 and 2 are the ones that matter. If they land and the benchmarks
reproduce, the rest is mechanical.

**Do not start Phase 1 while pfmatch threshold optimization is in flight** —
introducing a new reference-construction path mid-stream makes any movement in
match rate unattributable.

---

## 12. Honest counter-argument

The case for doing nothing: the current setup works, is producing measured
results, and a third package means three-way version compatibility. matchdb is a
real piece of software — realistically 2,000–3,000 lines with tests — and the
reproduce-exactly criteria above are demanding.

Not persuasive, for one reason. The complexity is arriving regardless: four more
sources are planned, and the current mechanism for absorbing a source is *a new
dev script plus a new suffixed CSV in `data-dev/`*. Seven near-duplicate
reference artifacts already exist. The choice is not between complexity and
simplicity; it is between complexity that is organized and complexity that
accretes.

What makes it worth it specifically is §6a, §6b and §9 — corpus statistics that
shift with the reference, a promotion rule that cannot see which variant it fired
on, and normalizer drift. All three are latent in the current process, and all
three are the kind of bug that surfaces as an unexplained drop in match rate
months later. A formal spec with a stamped artifact makes them impossible rather
than merely unlikely. That, more than the tidiness, is the argument.
