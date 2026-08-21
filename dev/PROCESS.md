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
do not start Phase 1 "while pfmatch threshold optimization is in flight."

Both are right, and together they are contradictory, because the §6b fix *moves
the YES/MAYBE boundary*. Adopting it mid-optimization contaminates the
optimization exactly the way a new reference path would.

**Status, 2026-08-21 — the window is open, and it is narrower than "before
sweeping starts."** `pfmatch/dev/OPTIMIZATION-PLAN.md` sequences the work in five
steps and is at step 3. Sweeping is step 4, and the plan closes with **"Do not
start at step 4"**: no tier boundary can be moved until §1b's ~600-case gold set
spans all three tiers, because every existing label sits inside MAYBE and tuning
a boundary on labels drawn from one side of it is circular.

So nothing is currently being optimized, and the fix can land now. But the
binding constraint is **not** the start of sweeping — it is the **drawing of the
gold set**, one step earlier:

> §1b draws its strata *by tier* — 250 YES, 250 MAYBE, 100 NO. The `variant_class`
> gate moves cases across the YES/MAYBE boundary by construction. Draw 600
> tier-stratified labels first and the fix silently re-tiers part of the sample,
> so the strata no longer mean what their names say and the set has to be
> re-drawn — after the labelling has been paid for.

Resolution:

* **Measure now.** The A/B is read-only: build both references, run the 1k
  benchmark, report the delta. It touches no shipped default.
* **Adopt before the gold set is drawn** — i.e. before
  `OPTIMIZATION-PLAN.md` step 3, not step 4. That is the last cheap moment. If it
  slips past, the fix waits for the entire optimization round to conclude.
* **Note the 99 already-drawn cases.** `data-dev/LABEL-FRAME-REFTIER.csv` holds
  `MAYBE_to_YES` (47), `NO_to_YES` (36) and `YES_contested` (16), drawn under
  current tiering. The `YES_contested` stratum is the one the fix could move.
  Re-drawing 99 is cheap; re-drawing 600 is not. This is the argument for
  sequencing the fix ahead of the main draw rather than after it.

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

**Qualify every phase number with its repo.** pfmatch and matchdb both number
phases from 0, and they mean unrelated things — pfmatch Phase 2 is "the
development databases", matchdb Phase 2 is "Schedule I as `observed`". A bare
"Phase 2" in a cross-repo note is ambiguous, and the ambiguity assigns work to
the wrong team rather than merely confusing a reader. It has already happened
once: `pfmatch/dev/REFERENCE-TIER-FINDINGS.md` §7 asked for top-K candidate
retention "in the Phase 2 partitions", which reads as a matchdb deliverable and
is not one — candidate pairs are match output, not reference data. Now
disambiguated in place. Write "pfmatch Phase 2" or "matchdb Phase 2", always.

---

## 4. Phase 0 — four workstreams, only one of them in this repo

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

### A hazard the ladder must carry forward

`pfmatch/dev/REFERENCE-TIER-FINDINGS.md` (2026-08-21) measured something the plan
does not currently guard against. §8 controls expansion — the *growth* direction,
where variants multiply rows. The measured danger runs the other way.

Of 569 YES on the active-BMF reference, **16 (2.8%) resolve to a different EIN**
on the augmented one, and **12 of the 16 fall to MAYBE** once the sibling row is
present. They are arm/operating pairs — `REGIS HIGH SCHOOL PROPERTY` vs
`REGIS HIGH SCHOOL`, `TEXAS CHILDRENS HOSPITAL` vs `... FOUNDATION`. The thin
reference does not contain the sibling, so the cascade never sees a contest,
matches to whichever member it holds, and auto-accepts. Separately, **54 of 956
winning pairs (6%) stop being rare** on the larger reference, so the
`name_freq <= 3` promotion gate fires *more* on the thin one.

Both point the same way: **a smaller reference auto-accepts more, and some of
what it accepts is wrong.** Selecting fewer layers is therefore not a safe
cost-saving — it is a precision change, in the unfavourable direction, and it is
invisible because the removed sibling cannot appear as a competing candidate.

Two consequences for this ladder:

* **`md_compile()`'s shape report (§8) must report absence, not just volume.**
  Rows-per-EIN and rows-per-source describe what a spec emits. What matters here
  is what it *omits* relative to the fullest available spec — at minimum, the
  count of selected EINs whose `ein_relation` siblings are excluded by the chosen
  layers.
* **Named tiers should carry the warning.** `active-legal` is the thinnest
  published spec in §7b, and is exactly the configuration measured above. It is
  legitimate to ship, but its documentation should say what it costs rather than
  reading as the safe default because it is the smallest.

**Landed** as `PLAN.md` §8a ("Contraction is the unguarded direction"), the
symmetric guard to the row budget. It adds a fourth guard — report absence, not
just volume — and notes the dependency: `ein_relation` arrives in Phase 4, so
until then the compile report must *say it cannot measure this* rather than print
a shape summary that reads as a clean bill of health.

---

## 7. What needs deciding

1. ~~**Threshold optimization — where does it stand?**~~ **Answered** by
   `pfmatch/dev/OPTIMIZATION-PLAN.md`: it is at step 3 of 5, blocked on a
   ~600-case gold set, and explicitly must not proceed to sweeping before that
   exists. Nothing is being optimized, so the window is open and Phase 1 is not
   blocked. What replaces this as a decision is narrower and time-bound —
   **land the `variant_class` fix before the §1b gold set is drawn**, per
   Collision B. That is a scheduling commitment someone has to make, not a
   question with an answer sitting in a file.
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

~~Commit the untracked evidence in `pfmatch/dev/`~~ — done, `pfmatch@daa4b03`.
~~Run 0a's determinism check~~ — done and passed, `pfmatch@eacd5c3`.

So: **take the 0a baseline manifest**, and do it before the `variant_class` fix
lands. The determinism result says a baseline will be reproducible once taken; it
does not take one. And the ordering now matters in a way it did not a day ago —
0c adds `variant_class` to `np_fields`, which changes the frame's column set. A
baseline captured after that change cannot serve as the "reproduces today's
behaviour" target for Phase 1, because "today" will already have moved.

Capture it from the current pinned pair, record the explicit column list per §5,
and the rest of Phase 0 can proceed in any order.
