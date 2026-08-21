# matchdb — build process

**Status: proposal, 2026-08-21. Companion to [`PLAN.md`](PLAN.md).**

`PLAN.md` decides *what* to build and in what order. This document decides *how
the work is actually conducted*: what has to be true before the first line of
code, how a phase is declared finished, and which of the plan's own instructions
collide and need resolving. It changes none of the plan's architecture.

---

## 1. The gap this closes

The plan's phase gates are the best thing in it:

> the spec `layers = bmf_active, names = legal+dba, addresses = mailing`
> reproduces today's `REF-active.rds` row-for-row, and pfmatch's `PF_SET=1k`
> benchmark is byte-identical.

That is a falsifiable criterion, and it is what keeps a refactor honest. But as
written it cannot be executed, for three reasons:

1. **There is no frozen baseline.** "Today's `REF-active.rds`" is a file in
   `pfmatch/data-dev/` produced by a `pfmatch` and an `npmatch` that are both
   under active development. `npmatch@5e23269` ("Fix apostrophe normalization")
   changed the normalizer *this cycle*. Comparing Phase 1 against a target that
   moves underneath it proves nothing.
2. **"Row-for-row" and "byte-identical" have no defined comparison semantics.**
   Row order, column order, factor levels and `""`-vs-`NA` will differ for
   reasons that carry no meaning. Without a stated normal form, the gate degrades
   into an argument about whether a diff counts.
3. **No phase produces the harness that evaluates the gate.** It is assumed to
   exist.

So the real Phase 0 is: **freeze a baseline and build the thing that judges it.**
Everything below follows from that.

---

## 2. Two collisions in the plan, and how to resolve them

**Collision A — the drift stamp cannot be delivered where the plan puts it.**

§9 requires, "from the first commit," that npmatch export
`np_normalize_signature()` and that matchdb stamp it into every artifact. That
function does not exist:

```
git grep -l normalize_signature main origin/main -- R/ NAMESPACE
grep -rn normalize_signature <R-library>/npmatch/NAMESPACE
# no matches in either -- source or installed package. Verified 2026-08-21
# against npmatch@fd17637.
```

It is an upstream change in a repo matchdb only *Imports*. It cannot be a matchdb
first commit; it is a **prerequisite pull request against npmatch** that must
merge before matchdb writes its first cached artifact. Treated otherwise, the
first thing matchdb ships is an unstamped cache — precisely the correctness
liability §9 exists to prevent.

This is not hypothetical risk. The normalizer has already drifted once during
this project's lifetime, with a measured recall consequence. `npmatch@5e23269`
rewrote `.np_strip_joiners()` to **delete** apostrophes and intra-word periods
before the general punctuation-to-space rule, because the IRS holds
`BO'S PLACE` as `BOS PLACE` while the old rule produced `BO S PLACE` on the
query side — 3.5% of 990-PF grantee names carry an apostrophe, and none of them
could clear an exact-name pass. It moved the 5,000-grant benchmark from 2,746 to
2,821 YES.

That is precisely the §9 failure mode, already realized: any artifact whose
`name_key` was built before that commit and read after it is normalized on one
side only, and the symptom is a recall drop with no error attached. The hazard is
observed, not anticipated.

Two calibrating notes. The drift was a *fix*, not a regression — the argument is
about cache validity across a normalizer change, not about code quality. And the
newest npmatch commits (`407f48f`, merged as `fd17637`) touch `R/normalize.R`,
`R/tier.R` and `R/veto.R` but are **comment-only**: stripping comment lines from
the diff leaves nothing. Since 0b hashes bodies after `utils::removeSource()`,
that commit correctly produces no signature change — a useful confirmation that
the hash granularity does not cry wolf on documentation.

**Collision B — the §6b A/B and the threshold optimization interfere.**

§6b says run the `variant_class` promotion A/B "before matchdb starts." §11 says
do not start Phase 1 "while pfmatch threshold optimization is in flight" — and it
is in flight (`pfmatch@fda58e1`, `dev/probe-threshold-recall.R`,
`dev/CASCADE.md` documenting `thresholds[yes] = 0.78`).

Both are right, and together they are contradictory, because the §6b fix *moves
the YES/MAYBE boundary*. Adopting it mid-optimization contaminates the
optimization exactly the way a new reference path would.

Resolution — separate measuring from adopting:

* **Measure now.** The A/B is read-only: build both references, run the 1k
  benchmark, report the delta. It touches no shipped default and cannot
  contaminate anything.
* **Adopt at a boundary.** Land the `variant_class` gate either *before*
  threshold optimization begins or *after* it concludes. Never during. If
  optimization has already begun, the measurement is banked and the fix waits.

---

## 3. Working agreements

These are cheap, and they are what keep the reproduce-exactly criteria meaningful.

**One phase, one branch, one gate.** A phase ends when its verification script
exits 0 on a machine that is not the author's — not when it looks done. Gate
output (the actual diff report) is committed to `dev/` as evidence, in the
established `*-FINDINGS.md` / `*.log` convention.

**No silent behaviour change.** matchdb's Phases 1 and 2 are *extractions*. Any
diff against baseline is either (a) representational — ordering, type,
empty-vs-`NA` — which the comparison normal form absorbs and which is documented,
or (b) behavioural — a different row, a different value — which stops the phase.
The classification is written down per diff, not decided in the moment. Category
(b) is never waived; the plan is explicit that behaviour change is the failure
mode this whole effort exists to avoid.

**Probes are committed with their logs.** Every measured claim in `PLAN.md` has
to trace to a tracked file, not to one that is a `git clean` from gone.
**Discharged for the existing evidence:** `pfmatch@daa4b03` tracks
`probe-idf-atomize.R` / `probe-refbuild-cost.R` and both logs;
`pfmatch@eacd5c3` tracks `probe-determinism.R`, three logs and
`DETERMINISM-FINDINGS.md`; `pfmatch@818c794` reduced the duplicated plan to a
pointer. The rule stands for everything added from here.

**Version pinning during a phase.** A matchdb phase pins the npmatch commit it
builds against, recorded in the phase's gate report. Unpinning is a deliberate
act with a re-run of the gate, not a side effect of `git pull`.

**Cross-repo changes are their own PRs.** npmatch changes (the signature
function, any `variant_class` awareness in `score.R`) land in npmatch, reviewed
on npmatch's terms, before the matchdb work that depends on them.

---

## 4. Phase 0 — three workstreams, only one of them in this repo

Phase 0 is larger than `PLAN.md` implies, and two thirds of it happens elsewhere.
It is also fully unblocked by the threshold-optimization freeze, so starting it
now costs nothing.

### 0a. Freeze the baseline *(pfmatch, ~1 day)*

Produce, from a single pinned `(npmatch, pfmatch)` commit pair, a
`BASELINE-2026-08/` manifest containing:

| artifact | why |
|---|---|
| `REF-active.rds` | Phase 1 target |
| `BMF-AUGMENTED-unified.csv` | Phase 2 target |
| `PF_SET=1k` tiered output | both benchmarks |
| md5 of each, row counts, the two commit SHAs, R and package versions | reproducibility |

**Determinism check first.** ~~Run the 1k benchmark twice from a cold cache and
confirm the outputs are identical.~~

**Done, 2026-08-21 — passed.** `pfmatch@eacd5c3`,
`pfmatch/dev/DETERMINISM-FINDINGS.md`. Three cold runs in separate processes —
two at seven `data.table` threads, one at one thread — produce bit-identical
output across all 24 columns of the tiered result (4,733 identities;
2821 YES / 1006 MAYBE / 906 NO in every run), compared with `identical()` rather
than any tolerance.

Thread-independence is the result that matters here: thread count is the
variable that actually differs between machines, so this is what discharges §3's
requirement that a gate pass "on a machine that is not the author's". The risk
was real rather than theoretical — `data.table` runs the blocking joins
multi-threaded and selection breaks ties first-row-wins in `.np_argmax_by()` and
`.np_overall_summary()`, which together are the standard recipe for a verdict
that drifts between runs. It does not drift.

Still untested: a second platform and R version. Nothing suggests risk, but one
confirming run is worth taking when a second machine is available.

This pins the *benchmark*, not the *baseline* — 0a's manifest is still to be
produced. What the check establishes is that such a baseline will be
reproducible once taken.

### 0b. Land `np_normalize_signature()` *(npmatch, ~1 day)*

A hash over `.np_abbrev`, the suffix list, `np_stopwords()`, and the bodies of
the functions in `R/normalize.R` that feed the derived columns. Exported, tested
for stability across a no-op edit and for change across a real one. Nothing in
matchdb can be safely cached until this exists.

**In progress** on `npmatch@feature/normalize-signature`. `PLAN.md` §9 carries
the full contract; the two decisions worth flagging here because they shape the
gate:

* **Scope is exactly what matchdb precomputes** — the normalizer's rule tables
  and functions, `np_stopwords()`, `np_name_freq()`, `np_token_idf()`, and the
  blocking tokenizer behind `np_ref_index()`. Comparison, scoring, veto,
  selection and tiering are deliberately **out**: none is precomputed, so a
  change there must not invalidate a cache. A signature that fires on unrelated
  edits teaches people to ignore it.
* **Comments and formatting must not move it.** Bodies are deparsed after
  `utils::removeSource()`. This is what makes "stability across a no-op edit"
  testable rather than aspirational.

Gate: exported and documented; a comment-only edit leaves the signature
unchanged; a rule-table edit changes it; `detail = TRUE` localizes which
component moved.

### 0c. Freeze vocabulary and run the promotion A/B *(pfmatch, ~2 days)*

Freeze the `layer` and `variant_class` enumerations (§3) — these become enum
constraints in the schema, and renaming them later rewrites data.

Then the A/B, extended past what §6b asks. §6a observes that the measured
"+43 YES" for the augmented reference is a *net* of aliases gained and promotions
lost, "and the two have never been separated." The A/B is the occasion to
separate them, because both arms have to be built anyway. Report four numbers,
not one:

* YES gained from alias rows matching
* YES lost to `name_freq` inflation tightening the promotion gate
* the same pair under `variant_class == "legal"` gating

That decomposition is the empirical justification for the whole variant-class
axis. If aliases-gained is small and promotions-lost is large, the plan's
priorities change — better to learn that for two days of measurement than after
Phase 2.

**Output:** `pfmatch/dev/VARIANT-CLASS-AB.md`.

### 0d. Scaffold matchdb *(matchdb, ~1 day)*

`DESCRIPTION` (Imports: npmatch, DBI, duckdb, arrow, data.table), `NAMESPACE`,
`R/`, `tests/testthat/`, and the verification harness below. No ingest, no
schema, no compile.

---

## 5. The verification harness — a first-class deliverable

Built once, in 0d, used by every gate afterwards. Lives in `dev/verify/`.

**Comparison normal form.** Before diffing any two reference frames:

1. restrict to the **baseline's** field set, captured as an explicit column list
   in the 0a manifest — not to `np_fields` as resolved at run time. `.ein` and
   `active` are already members (`npmatch/R/config.R:10`), so naming them
   separately is redundant; more importantly, `np_fields` is about to move.
   Phase 0c adds `variant_class` to it, so a normal form that reads the live
   constant would compare a baseline built without that column against a
   candidate built with it and report a diff carrying no information — or fail
   outright. **Pin the list; never resolve it from the installed npmatch.**
2. coerce all comparison columns to character; normalize `""` to `NA`
3. sort by `(ein, name_key, street_key, zip5)` and drop row order from the
   comparison
4. sort columns by name

**Report shape.** Three counts plus three sample tables: rows only in baseline,
rows only in candidate, and cells differing on jointly-present keys. The gate
passes when all three counts are zero.

Nothing here weakens the criterion. It removes the diffs that carry no
information so the ones that remain are unambiguously behavioural — which is what
makes "stop and reconsider" a decision someone can actually take.

**Benchmark comparison** is separate and stricter: exact equality on
`(ein_x, ein_y, tier, score)`, zero tolerance, having established determinism in
0a.

---

## 6. Phase ladder and gates

Phases are the plan's; the gate column is what this document adds.

| phase | repo | gate — passes when |
|---|---|---|
| **0a** baseline | pfmatch | manifest committed; ~~benchmark verified deterministic~~ **determinism done** (`pfmatch@eacd5c3`, thread-independent) — manifest outstanding |
| **0b** signature | npmatch | `np_normalize_signature()` exported and tested; matchdb can stamp |
| **0c** vocabulary + A/B | pfmatch | enums frozen; `VARIANT-CLASS-AB.md` reports the four-number decomposition |
| **0d** scaffold | matchdb | package skeleton; harness runs baseline-vs-itself and reports three zeros |
| **1** entity + name + address, BMF | matchdb | harness: `md_compile(active-legal)` vs `REF-active.rds` → three zeros; 1k benchmark exact |
| **2** Schedule I as `observed` | matchdb | vs `BMF-AUGMENTED-unified.csv` → three zeros; 1k reproduces the A/B's measured delta |
| **3** publication | matchdb | per-cell `df` recombination matches direct computation (< 1e-9, as measured); stamp mismatch **errors**; `latest.json` rollback exercised once |
| **4** remaining layers | matchdb | per-source, against the §8 row budget; shape report emitted |

Gate 0d is not ceremony. Running the harness on the baseline against *itself*
proves it reports zero when nothing changed; otherwise a Phase 1 pass is
unfalsifiable.

Phase 3's rollback exercise is the same principle. §7d's safety argument rests on
"rollback is editing a pointer," and a rollback path that has never been executed
is a claim, not a property.

---

## 7. What needs deciding

1. **Threshold optimization — where does it stand?** If it has not begun, 0c's
   fix can land immediately and Phase 1 follows. If it is underway, the A/B still
   runs now but the fix banks until it completes, and Phase 1 waits. This is the
   only item that changes the calendar.
2. ~~**`variant_class` in npmatch's `score.R`.**~~ **Settled** — `PLAN.md`
   Phase 0 adopts the recommendation below, and the two documents agree. npmatch
   grows an optional `variant_class` field in `np_fields`, defaulting to `NA` so
   no existing caller is affected. The alternative — matchdb encoding it into an
   existing column — was rejected because it reintroduces exactly the
   invisibility §6b exists to fix. Carried here only so the reasoning is not
   lost: `PLAN.md` §6b establishes that the provenance columns
   (`row_source`, `alias_n_filers`) are dropped at `.np_canonicalize()`
   (`npmatch/R/canonicalize.R:204`), so there is no existing column to encode
   into without corrupting one that means something else.
3. **Where the baseline lives.** `pfmatch/data-dev/` is gitignored and the frames
   are large. Either the existing `nccsdata` S3 asset tier with a manifest entry,
   or `dev/BASELINE-2026-08/` holding hashes and the benchmark output with the
   large frames on S3. Recommend the latter — the 1k tiered output is small
   enough to version, and it is the artifact the gates actually read.

---

## 8. Immediate next step

~~Commit the untracked evidence in `pfmatch/dev/`~~ — done, `pfmatch@daa4b03`
("Record the reference-rebuild cost probes: IDF is not the lever") tracks both
probes and both logs.

So: **run 0a's determinism check.** Two cold runs of the 1k benchmark, compared
for exact equality. One benchmark run answers a question every later gate depends
on, and it requires no decision from anyone.
