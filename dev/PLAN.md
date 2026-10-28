# matchdb — development plan

**Status: proposal, 2026-08-21. Updated 2026-10-23: Phases 0–3 run; the Phase 1
gate passes with three zeros; four tiers published.**

> **Where the work stands.** Phase 0 is finished (see `PROCESS.md` §6). Every
> planned source is ingested, so the archive is Phase 4 in scope: the BMF, NTEE,
> 1023-EZ, e-file headers, Schedule I, Schedule R, group exemptions, the 527
> filings, the 990-N e-Postcard (`postcard_only` layer), automatic revocations
> (`revoked_only` layer, with dates in `entity_event`), websites, and Part VII
> officer name keys (`person_key`; no titles or pay). A from-scratch build on
> `matchdb@bb68531` takes 70 minutes (63 of them deriving columns), gives a
> 10 GB database over 4.24M EINs (3.70M of them from the BMF), and passes `dev/check-build.R` 36 of 36.
>
> `REDUCTION.md` §8's build order is complete: derived columns (every
> `np_normalize()` column stored), the compact tables, `ein_key` with sharing
> counts, typed many-to-many clusters (`cluster`, `cluster_member`),
> `md_spec()` / `md_compile()`, and the named tiers.
>
> **Phase 1** (`dev/verify/run-gate.R`, baseline re-frozen as
> `dev/BASELINE-2026-10`): the BMF-only compile reproduces pfmatch's reference
> row for row; `name_freq` and `token_idf` are identical; the 1k benchmark is
> identical (0 of 4,715): **three zeros**. The first run left 4 cells, all
> `street_name` on EINs with no street, where npmatch wrote the text `"NA"`.
> That was an npmatch defect, fixed in `npmatch@ddfd967` (PR #17, signature
> `v1-6dcb298522cc5118`); on a rebuild with it and a re-frozen baseline the
> gate is exact.
>
> **Phase 2** (`dev/verify/phase2-measure.R`): Schedule I aliases with two or
> more corroborating filers add **+146 YES** on the 1k benchmark (295 gained,
> 149 lost), the direction 0c measured. With one filer allowed they cost
> **−527 YES**, so `min_corroborators = 2` stays the default.
>
> **Phase 3**: `md_publish()` writes parquet bundles stamped with the normalizer
> signature and md5s; `md_reference()` refuses a stale or altered bundle;
> `latest.json` is the rollback pointer. Published: `active-legal` (2.75M rows),
> `active-observed` (2.89M), `unified-legal` (4.98M), `unified-observed`
> (5.14M).
>
> **Matching one level up** (npmatch `np_cluster_rollup()`, `np_pair_links()`;
> `dev/verify/eval-cluster-rollup.R`): on 1,984 Schedule I queries with a
> reported EIN, matched against `active-legal`, 60 of 739 non-YES queries roll
> up to a family, and the true EIN is in it 90% of the time. Brand-type
> clusters were the weakest (1 of 5).
>
> **Next: stable identity and incremental updates** (`dev/IDENTITY.md`,
> proposed 2026-10-24, Phase 5 below). Row ids are still a running counter, and
> every ingest still replaces its source wholesale, so a newer BMF or e-Postcard
> overwrites the only history those sources have. The plan gives every name,
> address and observation a content hash and keeps one append-only observation
> ledger, with an update rule for each kind of source. Its step 0 is done: the BMF
> ingest no longer deletes every other source when re-run.

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

**Companion document.** `dev/PROCESS.md` covers *how the work is conducted* —
phase gates, the comparison normal form, cross-repo sequencing, and the open
decisions. This document decides what to build; that one decides how a phase is
declared finished. Where they disagreed, this one has been corrected.

**Evidence base.** The findings cited here live in `pfmatch/dev/`. Worth reading
before starting:

* `MATCHDB-PLAN.md` — the parent of this document
* `REF-PERFORMANCE.md` — measured cascade cost by reference size
* `PROMOTION-FLOOR-FINDINGS.md` — why the IDF gate was disabled
* `SCHEDI-ALIAS-FINDINGS.md`, `AUDIT-FINDINGS.md` — what the alias source buys
* `IDF-ATOMIZE.log`, `REFBUILD-COST.log` — the benchmarks behind §6c

One findings document lives in this repo rather than `pfmatch/dev/`, because it
was measured against `MATCHDB.duckdb` and the pinned baseline together:

* `GROUP-STRUCTURE-FINDINGS.md` — `group_id`, affiliate and group-return
  structure, and three rejected proposals. Read it before reopening §4's
  `ein_relation` or §10's affiliate paragraph.

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

Worse than untidy: **the cache is keyed by path, not by content.**
`pf_reference(cache = "data-dev/BMF-REFERENCE-BUNDLE.rds")` returns whatever
sits at that path, regardless of which BMF built it or with what options. With
seven near-duplicates on disk, silently matching against the wrong reference is
one stale file away. Spec-hash keying (§5) is what retires that, and it is a
correctness argument, not a housekeeping one.

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

### 3a. The frozen enumerations

**Normative. Frozen at Phase 0c.** These become enum constraints in the schema
and appear inside spec hashes, so renaming one rewrites data *and* invalidates
every artifact whose spec named it. Fixing the words now is the cheapest this
will ever be.

**`entity.layer`** — where the EIN came from. Exactly one per EIN; an EIN
present in several sources takes the strongest.

| value | meaning |
|---|---|
| `bmf_active` | in the current active BMF release |
| `bmf_inactive` | in some BMF release but not the current active one — revoked, merged, terminated |
| `filer_only` | observed on a 990-series filing (as filer, or as a Schedule I recipient with an EIN) but in no BMF release |
| `approved_only` | granted exemption on a Form 1023-EZ approval but in no BMF release |
| `irs527` | in the IRS 527 political-organization file and absent from the BMF |

Layer is *provenance* and is stable once assigned. `entity.active` is *status*
and flips (§7d). They are separate columns for that reason.

**`approved_only` was added 2026-08-21**, after the 1023-EZ ingest found 12,352
organisations the IRS had granted exemption to that reach no BMF release. None
of the existing values described them: `filer_only` means observed on a
990-series *filing*, and an approval is not a filing, so admitting them there
would have put a false statement in the provenance column — the one column whose
whole job is to be true.

Adding a value invalidates every spec hash that enumerated `layer`. That cost is
zero here because no spec has been published yet, which is precisely why the
addition happens now rather than after Phase 3. The rule stands for later: a new
layer is a deliberate act with a versioned artifact behind it, and the cheap
moment has passed once anything is published.

Note what the class does *not* assert. An `approved_only` organisation is real
and exempt; its absence from the BMF is a statement about the BMF, not about the
organisation. Reasons vary — approval too recent for the release, a subsequent
revocation, or a BMF gap — and the layer deliberately does not guess which.

**`name.variant_class`** — what kind of name string this row holds.

| value | meaning |
|---|---|
| `legal` | the source's canonical legal name for the EIN (BMF `org_name` / `org_name_join`) |
| `dba` | a doing-business-as name recorded by the source |
| `division` | a second alternate-name field (SAM `entity_division_name`) |
| `in_care_of` | the BMF in-care-of name |
| `observed` | a name a **third party** wrote about this EIN — Schedule I recipient names |
| `former` | a prior legal name, superseded by a later `source_vintage` |

**`address.variant_class`** — same idea for addresses.

| value | meaning |
|---|---|
| `mailing` | the correspondence address the source lists |
| `principal` | a distinct principal-office address, where the source separates the two |
| `observed` | an address a third party wrote — Schedule I |
| `historical` | superseded by a later `source_vintage` |

The distinction carrying the most weight is **`legal` versus `observed`**: first
party versus third party. That is the line §6b's promotion guard needs and
cannot currently see, and it is why `observed` appears in both tables meaning
the same thing.

**Deliberately not enum values.** Generated variants — acronyms, prefixes,
abbreviations — stay *derived columns* (`name_acro`, `name_pre`), never rows
(§10). Adding `acronym` here would double the name table for no blocking gain.
Reserve `observed` for an acronym actually seen in the wild.

**Amendment rule.** Append-only. Adding a value is cheap: existing rows keep
their class, new rows adopt the new one, and old spec hashes stay valid because
they never named it. Renaming or removing one is not cheap — it rewrites stored
data and silently changes what an old spec hash refers to. **Deprecate, never
delete or rename.**

---

## 4. Schema

Six core tables plus two relations. **Every key is an `EIN2`** —
`EIN-XX-XXXXXXX`, e.g. `EIN-00-0019818` — the stable identifier shared by the
e-file series, the BMF and the NCCS crosswalks. Leading zeros are the reason:
`00-0019818` read as a number is `19818`, and an EIN that has passed through a
spreadsheet or an untyped CSV read is a well known way to lose an organisation.
A string that cannot be coerced to a number cannot be silently renumbered.
`md_ein()` converts; `md_is_ein()` tests.

### What the BMF can and cannot supply

The unified BMF is **a snapshot, not a panel**: 3,698,124 rows over 3,698,124
distinct EINs, one row per organisation, carrying `first_vintage_ym`,
`last_vintage_ym` and `bmf_vintages_observed` rather than one row per vintage.

The rest of this section is built around the consequence. The BMF supplies the
*identity spine* and the *current* name and address. It cannot supply history.
History comes from the NCCS crosswalks — `ntee_resolved_crosswalk`,
`address_resolved_crosswalk`, `metadata-names` — which have already collapsed
each attribute into spells with vintage ranges and provenance. A design that
expects the BMF to yield a time series will quietly produce a single point and
present it as one.

### `entity` — one row per EIN, the layer axis

Three kinds of column, kept visibly distinct because they carry different
warranties.

```
-- 1. identity and lifecycle: invariant, or monotone
ein                 EIN2      PK
layer               enum      bmf_active | bmf_inactive | filer_only | irs527
active              bool      currently in the active BMF
first_vintage       ym        earliest vintage this EIN was observed in
last_vintage        ym        latest
n_vintages          int       how many vintages observed
ruling_date         date      IRS determination - the one near-invariant trait
bmf_source          text      which BMF series the row came from

-- 2. resolved attributes: value + rule + agreement, never a bare value
ntee_code           text      the resolved NTEE
ntee_rule           enum      current | most_recent | modal
ntee_agreement      enum      unanimous | mixed | single
ntee_n_distinct     int       distinct codes ever observed for this EIN
ntee_source         text      series the resolved value came from
nteev2              text      RECOMPUTED, never copied - see below
subsection          text  |  subsection_rule, subsection_agreement, ...
foundation_code     text  |  foundation_code_rule, foundation_code_agreement, ...
affiliation_code, group_exemption_number, group_exemption_is_member
```

**Almost nothing descriptive is invariant, and the schema has to say so.** The
temptation is to read NTEE and 501(c) status as fixed organisational traits and
store one value each. The data refuses: in the canonical NTEE crosswalk,
`ntee_agreement` is **`mixed` for 31% of EINs** — roughly a third have been
classified inconsistently across vintages. `ntee_current` is populated for only
34.7% of rows while `ntee_most_recent` is populated for 100%, because "current"
means *currently listed* and most EINs in the unified file are not in the active
BMF at all.

So every time-varying attribute arrives as a **triple — value, the rule that
produced it, and whether the underlying history agreed.** Store a bare
`ntee_code` and 31% of them look authoritative while being a coin flip; a
consumer filtering on NTEE has no way to know it is standing on a `mixed` value
resolved by an unstated rule. The crosswalk already publishes exactly these
columns, so this adopts its shape rather than inventing one.

`nteev2` is **recomputed** with `fiscal::get_nteev2()` at ingest, never copied
from a source. Both the BMF and the NTEE crosswalk ship an `nteev2` rendering
carrying the specialty double-encoding defect — `B11` as `EDU-B11-MS` where the
correct value is `EDU-B00-MS`, because digits 01–19 encode organisation *type*
and belong in the suffix, not the activity slot. Recompute from
`ntee_code_raw`, not from a cleaned three-character code: the legacy
five-character form carries the `B8443 → B43` rule, which truncation destroys.

`layer` is provenance (which tranche this EIN came from); `active` is status.
Keeping them apart is what lets an update flip status without rewriting
provenance.

**What is deliberately not here.** `asset_amount`, `income_amount`,
`revenue_amount`, `tax_period` and the filing-requirement codes are
point-in-time facts about one filing year, on a table whose grain is the
organisation's entire life. Putting them on `entity` means silently publishing
whichever year the source snapshot happened to carry. They are also not
candidate-generation signal — the same argument §10 makes for keeping mission
text out of the variant machinery. If size is wanted later it is an
`entity_financials` sidecar keyed `(ein, tax_year)`, not a column here.

**No legal-name column either.** The legal name is a `name` row with
`variant_class = 'legal'`. Storing it on `entity` duplicates it and re-creates
the primacy problem §7d exists to avoid; derive it in the compiled reference
instead.

### `name` — many rows per EIN, the variant axis

```
name_id             bigint    PK
ein                 EIN2      FK
name_raw            text      as written by the source
variant_class       enum      legal | dba | division | in_care_of |
                              observed | former
source              enum      bmf | schedi | efile990 | irs527 | meta_names
source_vintage      text      "bmf-2026-08", "schedi-2009-2024"
n_obs               int       times observed (NULL for BMF)
n_corroborators     int       distinct filers who wrote it (Schedule I trust)
first_year, last_year
-- observed rows only; see md_guard_observed() and OBSERVED-NAME-GUARDS.md:
n_self_filers       int       filers who wrote their OWN EIN for this name
filer_ein_lo, _hi   EIN2      range of the other filers (2+ filers iff lo <> hi)
flag_placeholder_ein, flag_placeholder_name, flag_own_ein,
flag_group_central, flag_multi_name   bool   wrong-EIN guards
guard_any           bool      any flag_*; the spec filter is NOT guard_any
name_ein_consistent bool      shares a distinctive word / abbreviation with the
                              EIN's first-party names (NULL: none to compare)
-- derived, computed once at build:
name_key, name_full, name_gen, name_gen_rank, name_nums,
name_ord, name_dir, name_form, name_acro, name_pre,
name_tokens         text      cleaned, deduped token set (see §6c)
```

Corroboration is not a substitute for the guards: a 2-filer floor drops most
flagged rows only by dropping 78% of Schedule I, and what it keeps is the
systematic kind (the PC(USA) EIN written for congregations by 32 filers). The
guards are flags, not exclusions, so the raw observation stays citable.
Measured in `OBSERVED-NAME-GUARDS.md`.

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
ein                 EIN2      FK
name_id             bigint    NULL — the pairing link, see §8
street_raw, unit_raw, city_raw, state, zip5, zip_plus4
variant_class       enum      mailing | principal | observed | historical
spell_rank          int       0 = most recent spell, ascending into the past
source, source_vintage, n_obs, n_corroborators, first_vintage, last_vintage
-- derived:
street_key, street_num, street_name, street_type, street_unit,
is_po_box, city, zip3, zip9, lat, lon, county, cbsa, tract
```

The `name_id` foreign key is not decoration. It is what stops the cross-product
blowup in §8.

`spell_rank` comes from `address_resolved_crosswalk`, which has already resolved
each EIN's address history into ranked spells with vintage ranges. **Historic
spells are archive, not current**: a spell with `spell_rank > 0` describes where
an organisation used to be, and compiling it into a reference as though it were
a present address is a false-match generator. Selecting historic addresses must
be an explicit spec choice, and `variant_class = 'historical'` is what makes it
one.

### `orgtext` — mission and program text

```
ein, tax_year, text_kind (mission | program_1..n | ntee_desc), text, source
```

EIN-keyed, deliberately outside the name/address selection logic. See §10.

### `ein_relation` — affiliate and dyad structure

```
ein_a               EIN2
ein_b               EIN2      NULL when the counterparty has no EIN
related_name        text      the counterparty as written, when ein_b is NULL
relation            enum      disregarded_entity | group_member | group_parent |
                              affiliate | related_entity |
                              dyad_substitutable | successor
relation_raw        text      the source's own wording, unmapped
controlled_512      bool      §512(b)(13) controlled entity. Schedule R Part II
                              only; NULL everywhere else, and NULL for a blank box
evidence, confidence
```

Every writer names its columns via `.md_relation_cols()` rather than relying on
position. Positional `INSERT ... SELECT` is why this table went five commits
without a boolean it needed: adding one would have shifted a value in all eight
writers silently, and a shifted value is not an error. A future column is added
in two places — the `CREATE TABLE` and that helper — and every ingest keeps
working.

### 4a. The relation vocabulary

These words already mean specific things in the sector, and an earlier draft of
this build used `affiliate` as a catch-all for six different disclosures. That
was wrong: in nonprofit usage "affiliate" means a **federated chapter**, which is
close to group structure and nothing like a hospital system's taxable subsidiary.
The enum is ordered by **strength of tie** - how substitutable the two EINs are -
because that is the axis a matcher acts on.

| relation | definition | sources |
|---|---|---|
| `disregarded_entity` | not a separate taxpayer; activity reported on the other's own return | Sch R Part I |
| `group_member` | IRS group exemption - applied for, GEN-registered, granted by the IRS | BMF GEN, 990 line H(c), NCCS historical, `AffiliateListing` |
| `affiliate` | federated chapter structure **without** a group exemption | none yet - see below |
| `related_entity` | control, ownership, or shared governance | Sch R Parts II/III/IV, Sch C Part II-A, 527 Sch R |
| `coalition` | coordination without control | **derived, never stored** |

`group_parent` remains reserved for the inverse direction and is unused - a row
already reads "`ein_b` is a `relation` of `ein_a`", and storing both directions
doubles the table to say nothing new. `dyad_substitutable` and `successor` are
likewise unused so far.

**`affiliate` is defined and deliberately empty.** The population is real -
4,774 organisations carry BMF `affiliation_code` 1 or 2 (network parent,
network intermediate) and **not one of them has a GEN**, which is exactly
federated structure outside the group exemption process. But the BMF names the
*parents* and never says which organisations report to them, the same wall
`md_ingest_relations()` hits with intermediates. So the category is defined,
holds zero rows, and will until a source states the edges. That is better than
leaving it as a catch-all: nothing is mislabelled into it now.

**The IRS uses the word differently, which is where the confusion started.** The
e-file element for a group-return roster is literally `AffiliateListing`, so the
IRS says "affiliate" where this vocabulary says `group_member`. That source
correctly produces `group_member` rows despite its name.

**`coalition` is a latent construct, not a disclosure.** Two organisations that
both support the same 501(c)(4) or 527 coordinate without sharing governance -
but no filing states that tie. It is inferred from co-membership over a shared
counterparty, so it is derived at consumption time from the observed relations,
never materialised. Materialising it would also be a clique, which §4 forbids on
its own.

Two judgement calls worth recording, because both went against first instinct:

* **Schedule C Part II-A is `related_entity`, not `coalition`.** §4911(f) defines
  an affiliated group by a *control* test - one organisation bound by another's
  decisions on legislative issues, or enough board overlap to control them - and
  834 of its 886 edges (94%) already exist as Schedule R Part II edges. A looser
  tie would not overlap that heavily.
* **527 Schedule R is `related_entity`, not `coalition`.** A "connected
  organisation" established, administers or funds the political organisation.
  That is a support and control tie. The coalition is the *derived* relation
  between two organisations connected to the same one.

A `relation` value can be revised without re-ingesting, because `relation_raw`
and `evidence` preserve what the source actually said. Promotion out of
`related_entity` - splitting controlled-by from merely-related, say - is a
mapping change.

**`relation_raw` now carries the controller, not the activity.** An earlier
version put `SR_02_RLTD_ORG_PRIMARY_ACT` there, so Part II's raw values read
`HOSPITAL`, `low-inc hsng` - the counterparty's *activity*, which is a property
of the organisation and not of the relation. It now holds the direct controlling
entity as written (688,328 rows) or the filer's explicit `N/A` (99,090), so the
values read `MERCY HOUSING INC`, `TRINITY HEALTH CORPORATION`. Dropping the
activity costs nothing *here and only here*: Part II counterparties are exempt
organisations and 119,865 of 119,865 resolve into `entity`, so each one's
activity is on its own record. Parts III and IV resolve at 5-9% and keep theirs.

Note `relation_raw` is unmapped by contract, so a filer who typed `NA` rather
than `N/A` appears verbatim as `NA` (65,968 rows). Normalising it would be a
mapping, which belongs downstream.

**The sharper signal is `controlled_512`.** `SR_02_RLTD_ORG_CTRL_512_X` - is the
counterparty a §512(b)(13) controlled entity - is a statutory yes/no, **93.1%
populated** against 68.8% for the controller name, and unlike a controlling-entity
name it answers the control question directly rather than by inference. It is
now a column.

Two encoding decisions worth knowing before filtering on it. The source writes
the flag four ways across schema versions (`0`/`1` and `false`/`true`); both are
normalised, and **anything else becomes `NULL` rather than `FALSE`** - a blank
box is silence, not a denial, and coercing it would invent 449,599 assertions
nobody made. Aggregating to one row per pair uses `bool_or`, so a pair is `TRUE`
if control was asserted in *any* year; `bool_and` would let a single year with
the box blank erase a relationship stated in every other year.

It is `NULL` for every source but Part II, because no other disclosure asks.

Where affiliates go. Not the name table. See §10.

**`group_id` is derived from this table, not stored in it.** Connected
components over `relation = 'group_member'` give 3,643 groups covering 446,492
EINs — 12.1% of the BMF. It is a derived column in the §3 sense (always built,
never selected), and it has to be derived rather than stored because GEN is not
stable: a single logical group is already split across multiple GENs today
(Lions 4, AAU 7, 4-H 12), and Rev. Proc. 2026-8 forces central organisations to
terminate all but one ruling by 2027-01-22. GEN is evidence feeding the key, not
the key.

Two constraints on the derivation, both measured:

* **Only `group_member` edges form the components.** Unioning `affiliate` edges
  in produces a 37,163-EIN giant component across the health-system and
  university sectors.
* **Schedule C is not a third structure.** 91.6% of its undirected pairs are
  already Schedule R edges; it lands as `relation='affiliate'`,
  `evidence='schedule_c_part_ii_a'`.

`dev/GROUP-STRUCTURE-FINDINGS.md` carries the evidence and the rejected
alternatives.

`ein_b` is nullable because two real sources cannot fill it. The 527 Schedule R
gives a counterparty name and address but no EIN, and only about 10% of those
names correspond to a known 527 at all. Resolving a name to an EIN is a
*matching* problem, which is `npmatch`'s job — so matchdb records the relation
with the counterparty named and leaves `ein_b` open rather than guessing.

`relation_raw` exists because the source vocabularies are not enumerations.
527 Schedule R's `ENTITY_RELATIONSHIP` has 528 distinct values; `Connected` and
`Affiliated` cover 97.4% and the tail runs to `Mother` and
`Common candidate-CA 33rd Assembly Dist.`. Keeping the raw string means the
mapping onto `relation` can be revised without re-ingesting.

### `source_vintage` — the audit table

```
vintage_id, source, origin (remote | local), url,
fetched, built,                                   -- when acquired / when loaded
content_vintage, content_vintage_rule,            -- what period the data describes
upstream_etag, upstream_modified, upstream_size,
local_md5, row_count, rows_added, build_note,
npmatch_version, normalize_signature
```

One row per ingest. This is `np_manifest()` promoted from a CSV of files to a
table of loads, and it is what makes any compiled reference explainable six
months later.

**Three dates, not one, because they differ and only one of them answers "is
this stale?"**

| column | means | example |
|---|---|---|
| `content_vintage` | the period the data *describes* | `2026-07` |
| `upstream_modified` | when the file was *published* | `2026-08-11` |
| `fetched` | when we *downloaded* it | `2026-08-21` |
| `built` | when the table was last *loaded* from it | `2026-08-22` |

The BMF makes the case: published 2026-08-11, but the newest vintage inside it
is **2026-07**. `md_ingest_bmf()` already computes that and puts it in
`build_note` as prose, where it cannot be queried.

`fetched` and `built` differ too. `fetched` is copied from the pin, so
re-running an ingest against an unchanged source leaves it untouched — there is
currently no way to ask when a table was last built, which is exactly the
question after a bug fix.

**`content_vintage_rule` records how the date was obtained**, on the same
value/rule/provenance discipline the NTEE triple uses:

| rule | when |
|---|---|
| `measured` | read from the data itself — BMF `last_vintage_ym`, e-file `TAX_YEAR`. Preferred, and available more often than expected. |
| `declared` | supplied by the collector. The only honest option for a hand-delivered file. |
| `published` | fell back to `Last-Modified`. Recorded as a fallback so a publication date is never mistaken for a content date. |

The fallback matters because it is the common case: **27 of 33 loads have no
`upstream_modified` at all.** The e-file CSVs, the locally supplied crosswalks
and anything hand-delivered return no date, so automatic extraction is the
exception rather than the default. `md_source_pin(content_vintage = )` therefore
takes an explicit value, and `version` stays what it is — an identifier and a
directory name, not a claim about time.

`upstream_etag` is not decoration either. The canonical BMF is published at a
`latest/` key that is overwritten in place, so "the BMF as of latest" is not
provenance — the ETag is the only thing that identifies *which* BMF a row came
from. `md_source_pin()` records it; `md_source_moved()` reports whether upstream
has been replaced since.

`upstream_etag` is not decoration either. The canonical BMF is published at a
`latest/` key that is overwritten in place, so "the BMF as of latest" is not
provenance — the ETag is the only thing that identifies *which* BMF a row came
from. `md_source_pin()` records it; `md_source_moved()` reports whether upstream
has been replaced since. The last two columns are the §9 drift guard.

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
| **`active-observed`** | active | legal, dba, observed (≥2 corroborators) | mailing, observed |
| `unified-legal` | active + inactive | legal, dba | mailing |
| `unified-observed` | active + inactive | legal, dba, observed (≥2 corroborators) | mailing, observed |

> **Phase 0c changed which of these should be the default.** Measured on the 1k
> benchmark (`pfmatch/dev/VARIANT-CLASS-AB.md`), the aliases carry the entire
> YES gain (**+199**) while the inactive-EIN tranche is **−5 YES** for 1.76M
> rows — nearly all of the reference's size and, by §2's scaling, nearly all of
> its runtime. `active-observed` was not in the original set and is added here
> because it is the combination that buys the gain without the cost; on this
> evidence it, not `unified-observed`, is the right default. Confirm with a
> direct run before Phase 3 fixes the published tiers. The `unified-*` specs
> stay — resolving defunct grantees is a real use — but nobody should get the
> inactive tranche without asking for it.

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

> **Built 2026-10-27** (`dev/TRANCHES.md`). The files are split by layer and
> class but not by band, because most bands are tiny. No statistics cell spans
> two files. A tier compiled from its own tranches (about 1 GB for an
> active-layer spec) is identical to its published bundle.

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

### 7f. The local asset inventory — what publish must produce

Everything pfmatch caches on disk today, and what a spec change actually
invalidates. This is the checklist `md_publish()` has to satisfy.

**A — reference-derived. Spec-dependent; matchdb's responsibility.**

| asset | build cost | spec-dependent? |
|---|---:|---|
| normalized reference frame | 269.7 s | **no** — per-row, ships as columns |
| recovery keys `name_acro` / `name_pre` | — | **no** — per-row |
| `name_freq` | 27.5 s | yes — corpus statistic |
| `token_idf` | 22.8 s | yes — corpus statistic |
| `ref_index` | 87.8 s | yes — posting lists |
| *bundled today as* `BMF-REFERENCE-BUNDLE.rds` | 408 s build, 51 s read | 1.30 GB (augmented: 2.84 GB) |

**B — EIN-keyed. Layer-dependent but *not* variant-dependent.**

| asset | size | note |
|---|---:|---|
| `ORG-TEXT-BUNDLE.rds` | 1.46 GB | mission / program / NTEE text by EIN |
| `PF-DYADS.rds`, `PF-DYADS-UNIFIED.rds` | 123 MB each | two copies exist **only** because the `in_bmf` flag is layer-dependent |
| `AFFIL-LINKS.rds` | 88 MB | Schedule A/R links, EIN-pair keyed |

**C — query-derived. Unaffected by matchdb.** Prepared grants and identities
(computed inline, uncached), `batches-*/` checkpoints (~1.7 MB per run, though
invalidated by any reference change), `nteev2.rda` (static package data).

Three consequences for the design.

**Category B is bigger than the reference.** `orgtext` at 1.46 GB is larger than
the entire reference bundle, which makes it a first-class distribution artifact
rather than the afterthought §10's framing might suggest. §10's point stands —
it stays out of the *variant machinery* — but it must be a published, layer-keyed
sidecar, not something a consumer rebuilds.

**Category B is layer-keyed, so it ships per layer set, not once.** The dyad
table already exists in two versions for exactly this reason: `in_bmf` is
computed against the reference EIN set (`pfmatch/R/dyads.R`, the `bmf` argument
sets that one flag and nothing else). Publish these keyed on the *layer* subset
of the spec hash — coarser than the full spec, so `unified-legal` and
`unified-observed` share one copy.

**Sizes above are uncompressed.** Every `saveRDS()` in pfmatch passes
`compress = FALSE`, deliberately, to trade disk for load speed. Do not size the
S3 bucket from these numbers — as parquet with dictionary encoding and zstd this
text compresses several-fold. Measure before provisioning.

**A tiered result frame costs 242 MB — until one attribute is dropped.**
Measured while running the determinism check, then run down while freezing the
0a baseline. `as.data.frame()` does not drop a subclassed frame's attributes,
and `np_cascade()` attaches the full scored candidate-pair table to its result
(`attr(res, "pairs") <- union`). Of a 197.8 MB object, `pairs` is **194.4 MB**;
the frame itself is ~3 MB.

Setting `attr(x, "pairs") <- NULL` before saving took the two 0a baseline
outputs from 9.65 MB and 16.64 MB to **0.163 MB and 0.165 MB** compressed — 60x
and 100x — keeping `config`, `profile` and `stages`, which record the thresholds
and pass table a gate will want to read later.

Retaining the pairs is deliberate and correct: `np_route()` needs them, and it
is what let Phase 0c recover variant class post-hoc with no npmatch change. But
**anything persisting a result is storing them by default**, so a gate archiving
result frames would pay a quarter-gigabyte a run for data it does not read.
Strip the attribute, and archive the diff report rather than the frame.

### 7g. What the consumer has to build

The answer the whole design is aiming at:

* **Published spec — nothing.** Category A ships whole in the Tier-1 artifact;
  category B ships as layer-keyed sidecars. Total local compute: zero.
* **Custom spec — one asset, effectively.** `ref_index`, at 88 s, until per-cell
  posting lists land (deferred in §6c). `name_freq` and `token_idf` recombine in
  0.03 s from cell vectors, and the frame is a partition-pruned read with derived
  columns already present.

The only genuinely unavoidable local work in either case is query-side
normalization of the grant file — a function of the query, not the reference, and
therefore not something matchdb can or should cache.

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
Keep it, make it universal — and see §8a, which adds what the spec *omits* to
what it emits.

### 8a. Contraction is the unguarded direction

The three guards above bound growth, because growth is where the cost is. The
measured danger runs the other way, and nothing above catches it.

`pfmatch/dev/REFERENCE-TIER-FINDINGS.md` (2026-08-21, 1,000 identities, active
BMF vs augmented) set out to justify a cheap-reference-first design and found the
opposite. Of **569 YES** on the thin reference, **16 (2.8%) resolve to a
different EIN** on the augmented one, and **12 of those 16 fall to MAYBE** once
the sibling row is present:

```
BOSTON CHILDRENS HEART FOUNDATION   ->  BOSTON CHILDREN HOSPITAL
UNIVERSITY OF KENTUCKY RESEARCH FDN ->  UNIVERSITY OF KENTUCKY
REGIS HIGH SCHOOL PROPERTY          ->  REGIS HIGH SCHOOL
TEXAS CHILDRENS HOSPITAL            ->  TEXAS CHILDRENS HOSPITAL FOUNDATION
```

These are arm/operating pairs. The thin reference does not contain the sibling,
so the cascade never sees a contest, matches confidently to whichever member it
holds, and auto-accepts. It is the failure mode `pfmatch/R/dyads.R` exists to
fix, reintroduced upstream by reference selection.

A second, independent mechanism points the same way. **54 of 956 winning pairs
(6%) stop being rare** on the larger reference, so the `distinct_name_maxfreq <= 3`
promotion gate fires *more* on the thin one. That is §6a's monotonic-count
argument, measured: a smaller reference makes more names look rare, so it
promotes more, so it auto-accepts more.

**So: selecting fewer layers is a precision change in the unfavourable
direction, not a cost saving.** That matters here specifically because §5 makes
it a one-line user choice — `layers = "bmf_active"` is the shortest spec anyone
will write, and it is exactly the configuration measured above.

Worse, the error is undetectable from inside the thin run. The findings tested
four safety flags computable from the small reference alone; the best combination
caught **half** the risky cases while escalating **39% of all YES**. The reason
is structural: a flag computed from the thin run is being asked to detect the
absence of something it cannot see.

Two consequences:

**A fourth guard — report absence, not just volume.** Rows-per-EIN and
rows-per-source describe what a spec emits. `md_compile()` should also report
what the spec omits relative to the fullest available spec: at minimum, the count
of selected EINs whose `ein_relation` siblings are excluded by the chosen layers.
Note the dependency — `ein_relation` arrives in Phase 4 (§11), so until then the
compile report should *state that it cannot measure this* rather than print a
shape summary that reads as a clean bill of health.

**Named tiers carry the warning.** `active-legal` is the thinnest published spec
in §7b. It is legitimate to ship and some users genuinely want it, but its
documentation has to say what it costs, or it will be read as the safe default
because it is the smallest.

And the temptation is not even well-founded on cost. The same findings conclude
that the augmented reference is 2.2×, not an order of magnitude, and that the
full run fits in 81 hours on 12 shards with it: *"There is no cost problem to
solve."* Contraction buys little and risks precision. The default should be the
fullest reference the budget in §8 allows, with thinner specs an explicit,
documented choice.

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

Confirmed drift, not anticipated drift: `npmatch@5e23269` ("Fix apostrophe
normalization, gate geo credit on state, tighten promotion") changed the
normalizer *this development cycle*.

Required:

1. npmatch exports `np_normalize_signature()` — a hash over the normalizer's rule
   tables (`.np_abbrev`, suffix list, stopwords) and function bodies.
2. matchdb stamps it, plus the npmatch version, into every artifact and into
   `source_vintage`.
3. `md_reference()` / `md_compile()` compare the stamp to the installed npmatch
   and **error** (not warn), with the remedy: rebuild, or pin npmatch.

**Step 1 is a prerequisite pull request against npmatch, not a matchdb commit.**
`np_normalize_signature()` does not exist today, and it lives in a repo matchdb
only *Imports* — so it must merge upstream **before matchdb writes its first
cached artifact**. Sequenced any other way, the first thing matchdb ships is an
unstamped cache, which is exactly the liability this section exists to prevent.
See Phase 0.

### The signature's contract

Scope is the whole design question. A signature covering too little misses real
drift; covering too much invalidates good caches on changes that cannot affect
them. The rule: **cover exactly what matchdb precomputes, and nothing else.**

*Covered* — the per-row derived columns and the corpus statistics that ship with
a compiled reference:

* every rule table `np_normalize()` consults — `.np_abbrev`,
  `.np_legal_suffixes`, `.np_street_types`, `.np_street_type_set`,
  `.np_directions`, `.np_ordinals`, `.np_generation`, `.np_gen_rank`,
  `.np_state_abbr`, `.np_state_codes`, and the unit / PO-box patterns
* every function feeding those columns — `np_normalize()` and its helpers
  (`.np_basic_clean`, `.np_replace_tokens`, `.np_strip_suffix`,
  `.np_strip_lead_the`, `.np_street_key`, `.np_parse_zip`, `.np_parse_street`,
  the `.np_extract_*` family, `.np_to_state_abb`)
* `np_stopwords()`, `np_name_freq()`, `np_token_idf()`
* the blocking tokenizer behind `np_ref_index()` — `.np_tokenize()`,
  `.np_doc_freq()`

*Deliberately excluded* — comparison, scoring, veto, selection, tiering. None of
it is precomputed, so a change there must **not** invalidate a cached artifact.
Including them would produce exactly the false rebuilds that teach people to
ignore the check.

*Mechanism.* An md5 over a canonical serialization of the above. Function bodies
are deparsed after `utils::removeSource()`, so **reformatting and comment edits
do not move the signature while logic changes do** — the stability property
Phase 0b has to demonstrate. No new dependency: `tools::md5sum` is base R.

*Diagnosability.* A bare hash tells you a cache is stale but not why. The
function takes `detail = TRUE` and returns per-component hashes, so a mismatch
can be localized to the rule table or function that moved.

*Versioned output.* The returned string carries a format prefix, so that later
changes to *what* is hashed are themselves distinguishable from changes to the
normalizer.

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

"Out of the variant machinery" is not the same as "out of scope for
distribution", though — at 1.46 GB it is the largest single asset a consumer
would otherwise rebuild. It ships (§7f), it just does not participate in
selection.

**Per-source incremental differencing: defer.** Appends are easy; deciding "is
this the same address written differently, or a new one?" is where the bugs live,
and a full rebuild in DuckDB is minutes. Build `md_ingest_*()` as **idempotent
full loads keyed on `source_vintage`**. Combined with §7d's derived primacy, this
removes a whole class of drift bug at negligible cost.

> **Revisited 2026-10-24** (`dev/IDENTITY.md`, "Why this reverses §10"). The
> diff proposed there compares exact bytes only, so it never has to decide
> whether two addresses are the same place: that stays in the compact tables, as
> now. A full build now takes 70 minutes, not minutes. And a full reload cannot
> recover history that a snapshot source (the monthly BMF, the e-Postcard) has
> already overwritten.

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

**That exception turns out to be the highest-value item in the whole area, and
it is bigger than Schedule I.** The BMF assigns most subordinates the *parent's*
legal name — 75.2% of e-file `AffiliateListing` affiliates carry a BMF name
different from the one they report for themselves, and in 70% of group returns
*every* member shares one identical BMF name. So the subordinate's own name is
usually absent from the reference entirely. The e-file affiliate rosters supply
it. In a held-out retrieval test those tokens were 0.19% of the index and
carried 23% of the gain. Ingest `AffiliateListing` names as `observed` variants
on the subordinates' own EINs, all years — it is a `name`-table ingest of the
kind Phase 2 already performs, needs no schema change, and is worth pulling
ahead of the rest of Phase 4.

**Three things in this area were proposed, measured, and rejected**
(`dev/GROUP-STRUCTURE-FINDINGS.md`):

* **`semantic_group_id`** — a name-similarity cluster nested inside a structural
  group. Rejected: semantic cohesion is a function of `(variant_class, source,
  normalize_signature)`, so it is a property of the *spec*, not of the entity,
  and storing it would bake a spec into the database against §9. It is also
  redundant inside group rulings (modal name share 0.905) and destructive inside
  related-entity networks (78.1% of which have no two members sharing a name).
  Compute `same_group(A,B) AND name_similar(A,B)` pairwise at match time instead.
* **A `group_signature` token-union index** — union each group's member tokens
  into one composite row and block against 3,643 of those instead of 3.69M
  names. Rejected: it cannot be gated (84.9% of non-group EINs hit some
  signature; keeping 90% of true members admits 89% of non-members), it is
  biased toward large groups (62.6% of wrong top hits are bigger than the truth),
  and end to end it buys +1.0 point of rank-1 for +6% candidates.
* **Address unions** — same idea on addresses. Rejected: median 1.64 distinct
  cities *per member*, so a city+state block returns a median of 154 groups.
  Address stays a scoring feature.

**Generated variants stay columns, not rows.** Acronyms and prefixes are pure
functions of `name_key`. `pf_add_recovery_keys()` already computes them as
columns (`name_acro`, `name_pre`), which is strictly cheaper than a new row and
blocks just as well. Reserve `variant_class = 'observed'` for acronyms actually
seen in the wild — different information.

---

## 11. Phasing

Build order is **extraction, not fresh design**: every stage moves code that
already works and is already benchmarked.

> **Phase 0 is larger than the four paragraphs below, and two thirds of it
> happens in other repos.** `dev/PROCESS.md` splits it into four workstreams
> (freeze a baseline, land the npmatch signature, vocabulary + A/B, scaffold),
> and defines the comparison normal form every gate below depends on. Read both.
>
> **The benchmark is deterministic — checked, not assumed.** Three cold runs,
> two at seven `data.table` threads and one at a single thread, produce
> bit-identical output across all 24 columns (`pfmatch@eacd5c3`,
> `pfmatch/dev/DETERMINISM-FINDINGS.md`). Thread-independence is the part that
> matters, since thread count is what differs between machines. Every gate in
> this document rests on that result; without it none of them could falsify
> anything. Untested: a second platform and R version.

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

**Measuring and adopting are separate acts, and only the first is safe now.**
§6b wants the fix "before matchdb starts"; §11 says do not start while pfmatch
threshold optimization is in flight — and it is (`pfmatch@fda58e1`). Both are
right and together they contradict, because the §6b fix *moves the YES/MAYBE
boundary* and would contaminate the optimization exactly the way a new reference
path would. So: **measure now** — the A/B is read-only, builds both references,
reports the delta, and touches no shipped default. **Adopt at a boundary** —
land the gate either before optimization begins or after it concludes, never
during. If optimization is already underway, bank the measurement and wait.

While both arms are being built anyway, extend the A/B past what §6b asks and
report four numbers rather than one: YES gained from alias rows matching; YES
lost to `name_freq` inflation tightening the promotion gate (§6a); and the same
pair again under `variant_class == "legal"` gating. That decomposition is the
empirical justification for the entire variant-class axis. If aliases-gained is
small and promotions-lost is large, these priorities change — far better to
learn that from two days of measurement than after Phase 2.

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
adding `observed` at `min_corroborators = 2` reproduces the augmented BMF frozen
in 0a, and the 1k benchmark reproduces the A→B delta Phase 0c measured
(+199 YES / −67 MAYBE).**

Two corrections 0c forced, both worth heeding before this phase starts.

*Name the target by content, not by filename.* Three near-identically named
augmented CSVs sit in `pfmatch/data-dev/` — `BMF-AUGMENTED-unified.csv`
(3,880,431 rows), `-unified-fixed.csv` (3,880,431), and
`-bmf_unified_geocoded_2026-08-20.csv` (3,891,187) — and the reference bundle
records which one built it nowhere. `REF-augmented.rds` resolves to
`-unified-fixed.csv`, **not** to the 3,891,187-row artifact behind
`REF-PERFORMANCE.md`'s published figure. An earlier draft of this plan named
`BMF-AUGMENTED-unified.csv` as the Phase 2 target; that was the wrong file.
0a's manifest must pin the target by row count and md5.

*The historical "+43 YES / +10 MAYBE" is not the target and never was.* §6a
established it is a net figure; 0c established it also spans the inactive-EIN
tranche, and that it was measured against a different artifact. Use 0c's
numbers.

The row-clone hack is then retired and its behaviour is a selectable spec.

**Phase 3 — publication.** Per-cell `df` vectors (§6c), spec-stamped bundles
(§6a, §9), partitioned parquet (§7b), the three named tiers, `latest.json`.
Repoint `pf_reference()` at `md_reference()` with the local path as fallback.
This is the phase that pays back.

**Phase 4 — remaining layers.** `filer_only` EINs, 527s, `ein_relation`,
`orgtext`. Each is one ingest function against a proven schema. Two additions
from `dev/GROUP-STRUCTURE-FINDINGS.md`: derive `group_id` from `ein_relation`
(§4), and ingest e-file `AffiliateListing` names as `observed` variants (§10) —
the latter is a `name` ingest with no schema change and can move ahead of the
rest of the phase.

**Phase 5 — stable identity and incremental updates.** Content-hash ids for
names, addresses and observations; an append-only observation ledger; one update
rule per kind of source (cache, snapshot, series, mentions); derived columns keyed
on the string and the normalizer signature. The full plan and its build order are
in `dev/IDENTITY.md`. **Success criterion:** the Phase 1 gate stays at three
zeros, the Phase 2 measurement reproduces, and applying releases one at a time
gives the same database as rebuilding from the pinned files.

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
