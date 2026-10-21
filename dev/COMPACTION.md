# The compact form: process, schema, and a test against real data

**Status: proposal + experiment, 2026-08-23.** Companion to
[`REDUCTION.md`](REDUCTION.md) §3a–§3c and [`DECOMPOSITION.md`](DECOMPOSITION.md)
§3, which set the rules this document turns into an executable process and then
tests. Section references written bare point at `PLAN.md`; references to the two
companions above are named.

> **Answer to the question this document was commissioned to answer:** yes, the
> compaction process changes table structure, and it already has. Four gaps
> surfaced while drafting and testing this — three schema gaps fixed before the
> real run, and one process gap (§0.4) found *by* the first run, which is
> exactly what running the experiment was for. Section 0 records what changed
> and why the order matters. Section 5 is the real, reproduced result.

---

## 0. What had to change before compaction could be tested honestly

Three findings, each of the "looks fine until you check" kind `PAIN-POINTS.md`
already exists to catch.

**`name` had no `first_year`/`last_year`.** `REDUCTION.md` §3c ranks recency
fourth for names, and there was no recency to rank — `md_ingest_schedi()`,
`md_ingest_schedr()` and `md_ingest_efile_header()` all computed the values into
their staging tables and dropped them at `INSERT`. Fixed and backfilled:
9,662,561 name rows, 3,610,319 now carrying a year envelope.

**`address.first_vintage`/`last_vintage` was populated for exactly two of six
sources.** `bmf` and `meta_address` had it; `schedi`, `schedr`, `efile990` and
`f1023ez` did not, despite three of the four computing the values already
(`efile990`'s spell ranking depends on `last_year`, which was computed and then
not carried into the row it ranked). Same bug, a second table. Fixed the same
way — wire the computed value into the `INSERT` — and it surfaced a fourth
occurrence of the specific defect this session already has a name for below.

**Two more live `mode()` calls.** `md_ingest_f1023ez()` used
`mode(street_raw)`/`mode(city_raw)` to pick a representative address, the exact
non-deterministic tiebreak `md_modal_sql()` exists to replace, in the one ingest
that had not yet been converted. Neither the Schedule I determinism check nor
the code-8 review caught it, because both were scoped to what they were built to
check, not read generally — the general point being that a per-instance fix
does not generalize into a per-codebase guarantee, only a rule someone has to
keep re-applying by hand or a lint that enforces it. Moved onto `md_modal_sql()`.

**One finding, surfaced but not yet fixed: vintage format is inconsistent across
sources.**

| source | `last_vintage` format |
|---|---|
| `bmf` | `2026-07` (hyphen) |
| `meta_address` | `2026_06` (underscore) |
| `schedi` / `schedr` / `f1023ez` (post-fix) | `2024` (bare year, from `tax_year`/`approval_year`) |
| `efile990` (post-fix) | `2024` (bare year, from `first_year`/`last_year`) |

All four forms happen to be lexicographically sortable against each other as
strings *only* because every one leads with a four-digit year — `max('2024',
'2026_06') = '2026_06'` is correct by accident of digit order, not by design.
A format that ever failed that property (a two-digit year, a non-leading
qualifier) would silently misorder. **§3 below defines a single derived
`vintage_year` for compaction rather than trusting the raw column's sort order,
and that derivation, not a reformat of four ingests, is the fix.** Reformatting
the sources would only relocate the inconsistency; deriving a canonical sort key
from whatever is there removes the dependency on the sources ever agreeing.

**0.4 — the finding the first real run produced, not anticipated: re-ingesting
a source silently invalidates every derived table keyed on its row ids.**

Fixing 0.1–0.3 above meant re-running four `md_ingest_*()` functions. Each is
idempotent by *deleting* its own source's rows and *re-inserting* them — and the
re-inserted rows get **freshly assigned** `name_id`/`address_id` values
(`base_id <- max(id)` at the moment of insert), not a content-stable key tied to
what the row actually says. `name_derived` and `address_derived` had been built
against the *previous* set of ids, so after the four re-ingests they silently
stopped matching most of the table they were meant to describe.

The first compaction run — built on this stale join without anyone knowing it
was stale — produced a `name_compact` whose `variant_class` distribution showed
**zero** `observed` or `former` rows and a year-envelope fill of **exactly
0%**. Both looked like they could be real findings about the data. Neither was:

```
orphaned name rows:    3,610,319 of 9,662,561   (every non-BMF source)
orphaned address rows: 4,185,635 of 18,546,417
```

`address_compact` was unaffected by coincidence, not design — it derives
`street_key` from the raw column inline rather than joining
`address_derived`, so it never touched the stale table. That asymmetry is
itself worth noting: two tables built by the same process were exposed to the
same defect completely differently, for a reason that had nothing to do with
either table's importance.

**Fixed** by rebuilding both derived tables (75 minutes total: 27.6 for `name`,
47.3 for `address`) and reconfirming zero orphans on both. **Guarded** by
`md_check_derived_fresh()`, now called at the top of `md_build_compact()`,
which counts orphans on both sides and errors before anything downstream is
trusted. That closes the *silent*-failure mode. It does not close the root
cause: the next re-ingest of anything reopens the same gap until the derived
tables are rebuilt again, by someone remembering to. Two structural fixes would
close it for good, neither done yet:

* give `name_id`/`address_id` a content-stable derivation (a hash of the
  natural key) so an unchanged row keeps its id across a re-ingest, or
* have `md_ingest_*()` call `md_build_derived()` itself as a matter of course.

Recorded in full in `PAIN-POINTS.md` §1, because it is a hazard for every future
consumer of `name_derived`/`address_derived`, not only for compaction.

---

## 1. What "compact form" means, precisely

One row per `(ein, name_key)` in `name`; one row per `(ein, street_key, city_key,
state, zip5)` in `address`, after domination pruning. Every contributing raw row
is still on disk, untouched — `REDUCTION.md` §9 is unchanged, and this is a
second derived layer beside `name_derived`/`address_derived`, not a replacement
for `name`/`address`.

This directly answers the "does this change how tables are structured" question
a second way, beyond section 0's schema fixes: **the compact tables are new
tables, not a mutation of existing ones**, for the same reason `name_derived`
exists rather than columns bolted onto `name` — §9's normalizer-drift argument
applies equally to a re-derivation of the compaction rule. If the ranking in §3
changes, `DROP TABLE name_compact` and rebuild, rather than reconcile an
in-place update against append-only history.

---

## 2. `source_mask`: a registry, not an ad hoc bitmask

Merging rows from several sources into one needs a stable way to say which ones
attested it. A bitmask computed fresh per compaction run is a hazard the moment
a new source is added mid-project and shifts every existing bit — exactly the
kind of silent redefinition `PLAN.md` §3a's frozen-enumeration argument warns
about for `layer` and `variant_class`. So the assignment is a registry function,
alongside `md_layers()`:

```r
md_name_sources <- function() {
  c(bmf = 1L, efile990 = 2L, f1023ez = 4L, schedi = 8L, schedr = 16L)
}
md_address_sources <- function() {
  c(bmf = 1L, efile990 = 2L, f1023ez = 4L, schedi = 8L, schedr = 16L,
    meta_address = 32L)
}
```

New sources append a new bit; nothing already assigned ever moves. `popcount`
(rank 5 in `REDUCTION.md` §3c's ordering) is `bit_count(source_mask)` and
requires no further bookkeeping.

---

## 3. The `name_compact` process

**Group** by `(ein, name_key)` — collapsing across `variant_class` and `source`,
not within them. This is the one departure from a literal reading of
`REDUCTION.md` §3a worth arguing for explicitly: if the BMF calls an EIN
`X` and Schedule I independently observed the same string `X`, that is
corroboration of one fact, not two facts. Keeping them as separate rows because
they arrived through different pipes would double the row and lose the
reinforcement `n_corroborators` exists to capture.

**Representative spelling.** `md_modal_sql()` — frequency, tie-broken
alphabetically, exactly as the ingest layer already does. Never `mode()`.

**`variant_class`** takes the highest-precedence value contributing to the
group: `legal > dba > observed > former`, per `DECOMPOSITION.md` §3c. A name
attested as both `legal` (by the BMF) and `observed` (by Schedule I) is
`legal` — the precedent case is exactly the corroboration above, and legal
should win because it is the more specific claim, not because it arrived first.

**`n_corroborators`**: `max()` across contributing rows, not `sum()`. The two
sources count corroboration on different scales — a Schedule I `n_corroborators`
counts independent grantmakers, a BMF row has none — and summing would treat a
scale difference as additional evidence.

**`n_eins_sharing`**: `count(distinct ein)` over the same `name_key`, computed
in the same pass. This is `REDUCTION.md` §6b's `name_ambiguity` input, but note
what it is *not* yet: it counts how many EINs share a spelling, not whether
those EINs are affiliated. The `within_family` / `cross_family` distinction
needs `cluster_id` from `ein_relation`'s connected components, which this
document does not build — it is next, and §6 records exactly where this stops
short of it.

**`vintage_year`**: `greatest(...)` over every contributing row's year, each
parsed defensively — `TRY_CAST` the raw value, and where it is a compound string
take the leading four digits — rather than trusting any single column's format
uniformly. This is where the gap from §0 is actually closed, at the point of use
rather than at the point of storage.

**`source_mask`**: `bit_or` of each contributing row's registry bit.

```sql
CREATE TABLE name_compact AS
WITH keyed AS (
  SELECT n.ein, d.name_key, n.name_raw, n.variant_class, n.source,
         n.n_obs, n.n_corroborators, n.first_year, n.last_year
  FROM name n JOIN name_derived d USING (name_id)
  WHERE d.name_key <> ''
), spelling AS ( -- md_modal_sql(keyed, c("ein","name_key"), "name_raw")
  ...
), agg AS (
  SELECT ein, name_key,
         sum(n_obs) AS n_obs,
         max(n_corroborators) AS n_corroborators,
         min(first_year) AS first_year, max(last_year) AS last_year,
         bit_or(source_bit) AS source_mask,
         min(variant_rank) AS variant_rank   -- 1=legal .. 4=former
  FROM keyed GROUP BY 1,2
)
SELECT a.ein, a.name_key, s.name_raw, rank_to_class(a.variant_rank) AS variant_class,
       a.n_obs, a.n_corroborators, a.first_year, a.last_year, a.source_mask,
       count(*) OVER (PARTITION BY a.name_key) AS n_eins_sharing
FROM agg a JOIN spelling s USING (ein, name_key)
```

---

## 4. The `address_compact` process — two passes, not one

**Pass 1 — exact dedupe**, group by `(ein, street_key, city_key, state, zip5)`,
same aggregation shape as names (`source_mask`, `max(n_corroborators)`,
`greatest(vintage_year)`).

**Pass 2 — domination pruning**, only after pass 1, because domination is a
relationship *between* compacted rows, not raw ones, and running it against
18.5M raw rows rather than the ~12M compacted ones would do the same work at a
worse constant.

**The domination rule, made precise** (`DECOMPOSITION.md` §3b only sketched it):
within one EIN, row *A* is dominated by row *B* when

1. every field *A* populates, *B* populates with the same value, **and**
2. *B* populates at least one field *A* leaves null,

restricted to the fields that identify a place — `street_key`, `city_key`,
`state`, `zip5` — never the geocode enrichment columns (`lat`/`lon`/`tract`/
`geocode_type`). Enrichment is a property of *this* address row once geocoded,
not a criterion for whether a coarser row still deserves to exist; treating a
missing `tract` as "loses" would drop rows purely because geocoding had not
reached them yet, which is a processing-order accident, not a fact about the
address.

Implemented as: for each EIN, a row with `street_key IS NULL` is dominated if
another row for the same EIN has `street_key IS NOT NULL` and agrees on every
field the coarse row populates.

```sql
CREATE TABLE address_compact AS
WITH keyed AS ( ... source_mask, vintage_year as in name_compact ... ),
agg AS (
  SELECT ein, street_key, city_key, state, zip5,
         sum(n_obs) n_obs, max(n_corroborators) n_corroborators,
         min(vintage_year) first_vintage_year, max(vintage_year) last_vintage_year,
         bit_or(source_bit) source_mask
  FROM keyed GROUP BY 1,2,3,4,5
),
dominated AS (
  SELECT a.ein, a.street_key, a.city_key, a.state, a.zip5
  FROM agg a
  WHERE a.street_key IS NULL
    AND EXISTS (
      SELECT 1 FROM agg b
      WHERE b.ein = a.ein AND b.street_key IS NOT NULL
        AND (a.city_key IS NULL OR b.city_key = a.city_key)
        AND (a.state     IS NULL OR b.state     = a.state)
        AND (a.zip5      IS NULL OR b.zip5      = a.zip5))
)
SELECT a.* FROM agg a
LEFT JOIN dominated x USING (ein, street_key, city_key, state, zip5)
WHERE x.ein IS NULL
```

---

## 5. Measured, against the real database, post-§0 fixes

`dev/probes/probe-compaction.R`, run twice: once against the stale derived
tables (§0.4's discovery), once after rebuilding them. The numbers below are
the second run — the only one this document treats as the answer. Both compact
tables are built with `CREATE TABLE ... AS` from the live `name`/`address`/
`name_derived`/`address_derived`; nothing else is mutated, per §1's
DROP-and-rebuild posture.

### `name_compact`

| | count |
|---|---:|
| eligible input rows (`name`, `in_care_of` excluded) | 8,086,388 |
| compacted rows | 6,254,025 |
| reduction | 22.7% |
| EINs represented | 4,016,683 — every entity |
| groups with `source_mask` popcount ≥ 2 (corroborated across sources) | 1,153,167 (18.4%) |

`variant_class` after collapsing across sources:

| class | rows |
|---|---:|
| `legal` | 4,042,666 |
| `observed` | 1,173,324 |
| `dba` | 936,772 |
| `former` | 101,263 |

Every EIN has a name (rows/EINs above match exactly), and cross-source
corroboration is real and worth the design choice in §3: 1,153,167 groups —
nearly a fifth — are attested by two or more sources at once, which a
grouping scoped to `(ein, name_key, source)` would have kept as separate rows
and never revealed.

`legal` grew past the BMF's own legal-name count (3,698,124) to 4,042,666: the
difference is legal-ranked names for EINs the BMF does not cover at all —
`filer_only` and `approved_only` entities whose only legal name comes from
`efile990` or `f1023ez`. `former` fell from 197,251 raw rows to 101,263
compacted ones, which is the correct direction: a "former" name identical to
the current legal spelling is the same fact observed twice, not two facts, and
correctly collapses into the surviving `legal` row rather than persisting as a
redundant `former` beside it.

`n_eins_sharing` on the real compacted key (compare against `REDUCTION.md` §4's
1,308 keys / 706,255 rows, measured on raw `name` including `in_care_of`):

| EINs sharing a key | keys | rows |
|---|---:|---:|
| 1 — unique | 4,416,087 | 4,416,087 |
| 2–3 | 288,108 | 627,402 |
| 4–10 | 48,665 | 264,890 |
| 11–100 | 11,884 | 294,670 |
| **100+** | **1,164** | **650,976** |

Close to `REDUCTION.md`'s figure and not identical, and the gap is explained
rather than a discrepancy to chase: this table excludes `in_care_of` and
additionally collapses across sources within a group, both of which this
document's process does deliberately and `REDUCTION.md`'s original measurement
did not.

Year envelope: **43.7%** of compacted names carry a `first_year`/`last_year` —
zero before §0.4's fix, and a plausible number now given that roughly half the
eligible input is BMF-sourced (no per-row year by construction) and the rest
carries one.

### `address_compact`

| | count |
|---|---:|
| raw input rows | 18,546,417 |
| after pass 1 (exact dedupe on place) | 13,553,272 |
| dominated and dropped in pass 2 | 2,431,651 |
| final compacted rows | 11,121,621 |
| reduction, raw → final | 40.0% |
| EINs represented | 4,013,572 |

`source_mask` popcount — corroboration is common here too:

| sources | rows |
|---|---:|
| 1 | 7,425,757 |
| 2 | 2,983,787 |
| 3 | 589,746 |
| 4 | 112,699 |
| 5 | 9,608 |
| 6 | 24 |

`street_key` fill rose from 76.3% on raw `address` to **82.4%** after
domination pruning — coarse city/state-only rows are disproportionately the
ones removed, which is the rule working as designed rather than an incidental
side effect.

`vintage_year`, the derived canonical sort key §0.3 argued for instead of
trusting the raw column format: **100% filled**, range 1989–2026 — every row
got a year, including the ones whose raw `first_vintage`/`last_vintage` came
from three different string formats.

### What the domination rule actually caught

Six sampled EINs whose city/state-only address was dropped, each because a
fuller row for the same EIN already carries a street:

```
EIN-47-1421958  LEROY IL 61752            -> 4 fuller rows remain for this EIN
EIN-47-1432312  PATERSON NJ 07514         -> 3
EIN-47-1433249  ORLANDO FL 32819          -> 2
EIN-47-1447861  TIMMONSVILLE SC 29161     -> 1
EIN-47-1458098  CASTLETON VT 05735        -> 2
EIN-47-1461418  TEXARKANA TX 75503        -> 2
```

This is exactly `REDUCTION.md`'s original example — a coarse address dropped
beside a fuller one for the same organisation — not the failure mode the rule
was designed to avoid (two distinct addresses that happen to share a state,
which the rule leaves untouched because it never matches on state alone).

---

## 6. What this does not yet do — the honest boundary

**`n_eins_sharing` is not `name_ambiguity`.** It counts sharing, not affiliation.
Turning it into `unique` / `within_family` / `cross_family` needs `cluster_id`
from connected components over `ein_relation`, which is the next artifact, not
this one. Until it exists, `n_eins_sharing` is usable as a raw discriminative
signal (`REDUCTION.md` §3c rank 2) but not as the sharper structural feature
`REDUCTION.md` §6b describes.

**The address pairing link (§8) is not reconstructed here.** Compaction groups
by place, independent of which `name_id` an address was originally observed
with. That is correct for `address_compact` as a *identity* artifact — the
question "what addresses exist for this EIN" does not care which name a filer
happened to write beside it — but it means `address_compact` cannot itself
answer §8's pairing question. A compiled reference that wants the pairing rule
needs to consult `address.name_id` on the raw table, not the compacted one, for
that specific purpose. This is a scope boundary, not a defect: the two questions
("what addresses does this EIN have" and "which name was this address paired
with") are genuinely different questions and this document only answers the
first.

**Vintage remains multi-format in storage**, per §0; only the *derived* sort key
is canonical. A future pass could normalize the stored columns themselves, but
doing so now — before `npmatch`'s side of the decomposition (`DECOMPOSITION.md`
§4, `np_normalize(fields=)`) is settled — risks designing a format that has to
change again once that interface exists. Deferred deliberately, not overlooked.

**This document does not touch `npmatch`.** It produces the compact tables
`DECOMPOSITION.md` assumes as input. Whether npmatch consumes them as two
separate frames or as one is that document's question, not this one's.
