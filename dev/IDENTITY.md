# Stable IDs, change detection and folding in new vintages

**Status: in progress, 2026-10-24, reconciled with `main` at `d75d73c` (Phases
0–3 complete, four tiers published). Steps 0–2 are done. Step 3 is built and
tested; its measurement on a full database is pending. Steps 4–7 are not
started.**

This plan takes on three problems that remain after Phases 0–3:

1. Row ids are a running counter (`base_id <- max(id)`), so any re-ingest gives
   every re-loaded row a new id (`PAIN-POINTS.md` §1, `COMPACTION.md` §0.4).
   `md_build_derived(incremental = TRUE)` now stops that from orphaning derived
   rows, but it does so by re-normalizing every re-ingested row, and anything
   else keyed on those ids (`name_compact`, clusters, the `address.name_id`
   pairing link) has to be rebuilt as well.
2. A normalizer change means rebuilding all derived columns (63 of the 70
   minutes of a from-scratch build), with no record of what the change did.
3. A newer release of a source replaces the older one wholesale. For a source
   that republishes only its current state - the monthly BMF, the e-Postcard -
   the earlier values are thrown away, and with them the only history those
   sources have.

The proposal: **identify everything by a hash of what the source wrote, record
every observation in one append-only ledger, and give each kind of source its own
rule for how a new release changes that ledger.** The ingest functions do only
one job, which is parsing a file into a standard shape. A shared engine does
identity, diffing and writing.

### Why this reverses `PLAN.md` §10

§10 deferred per-source incremental differencing for two reasons. Both have
changed or don't apply here:

* *"Deciding 'is this the same address written differently, or a new one?' is
  where the bugs live."* This plan never makes that decision in the diff. Two
  rows are the same observation only if their bytes match after whitespace
  cleanup (§3). "Written differently" is still settled where it is today, by the
  normalized keys in the compact tables, and that stays a rebuild.
* *"A full rebuild in DuckDB is minutes."* A full build is now 70 minutes. More
  important, a full reload cannot recover history that a snapshot source has
  already overwritten. Only folding each release in as it arrives keeps it.

---

## 1. What happens on `main` today

**Each source is pre-aggregated before it is stored.** `md_ingest_schedi()`
collapses grant rows to one row per `(ein, light key)`, keeps the most common raw
spelling, and records `n_obs`, `n_corroborators`, `first_year` and `last_year`.
The individual grant rows are not kept. `md_ingest_efile_header()` does the same
per `(ein, variant_class, light key)`. The BMF and the e-Postcard write one row
per EIN per name field.

**`n_obs` means two different things.** For the return headers it is the number
of filings that carried the name, so a name kept for eight years counts 8, and an
amended return counts twice. For Schedule I it is the number of grant rows, so
one funder making three grants in one year counts 3. It is `NULL` for the BMF.
`md_compile()` uses it as a tiebreak when ranking names within a class.
`n_corroborators`, the number of distinct filers who wrote a name, is
well-defined. It sets the corroboration band (1, 2, 5, 20) that the statistics
cells and `min_corroborators` are built on.

**The same string from two sources is two rows.** A name in both the BMF and
Schedule I is one `source = 'bmf'` row and one `source = 'schedi'` row. They are
merged in `name_compact`, which ORs a `source_mask`.

**A new release replaces the old one wholesale.** Every ingest deletes its
source's rows and re-inserts them with fresh ids. No diff is taken, and the
earlier release's rows are gone. Only its `source_vintage` audit row remains.

**Re-running the BMF ingest deleted every other source.** `md_ingest_bmf()` used
`CREATE OR REPLACE TABLE` for `entity`, `name` and `address`, so it worked only
as the first step of a fresh build. **Fixed in step 0 (§8).**

**A year-partitioned source is all-or-nothing.** Schedule I 2009–2025 is pinned
as one set with one combined digest. Adding the 2026 file means re-reading every
year, and the pin cannot say which year files changed.

---

## 2. Four kinds of source

How a new release should change the database depends on what the publisher does
between releases. What one observation means depends on who is writing the name
and how often they can write it. Four patterns cover every source.

A naming note: the request called the second kind a *roster*. In this codebase
"roster" already means a group-return roster (`.md_roster_source()`,
`md_ingest_affiliate_listing()`), so the kind is called a **snapshot** here.

| kind | what the source is | unit of change | one observation is | corroboration means | on a new release |
|---|---|---|---|---|---|
| **cache** | compiled once; a new release is rare and is a correction | the whole file | one row as delivered, with any vintage range the file states | whatever the file states | diff the whole file: add new rows, retract missing rows |
| **snapshot** | republishes the current state, one row per EIN, overwriting old values | `(ein, field)` | one **spell**: an unbroken run of releases in which the field had the same value | how long the spell lasted | extend unchanged spells, close changed or vanished ones, open new ones |
| **series** | an organisation describing **itself** once per period (the 990 header, 1023-EZ) | one partition (a tax year) | one **period**: the value appeared in that year's filing | **how many periods** the value appeared in, i.e. how many years the name and address stayed the same | new partition: append. Re-released partition: diff it like a cache |
| **mentions** | **third parties** writing about an organisation, as often as they like (grants are the main case) | one partition, or one pooled file | one **row**: every time the name and address are written, including repeats in the same file and year | **how many times** the pair was written, and by how many distinct writers | as for series: append new partitions, diff re-released or re-pooled ones |

So two filings in two years count twice (series, two periods). The same BMF
record in two monthly releases counts once, with a longer spell (snapshot). A
grantee listed on three grants by one funder in one year counts three times by
one writer (mentions), whether the file holds one year or pools several.

Series and mentions update the same way. They differ in what they count: a series
counts **years**, and a mention counts **rows**. Keeping them separate stops a
grant total and a count of filing years from being added together as if they
measured the same thing, which is what `n_obs` does today.

### The registry, classified

| kind | sources on `main` |
|---|---|
| snapshot | `bmf_active` (monthly), `e_postcard` (one row per EIN: its latest postcard). Future: Pub 78 |
| snapshot seed (§2a) | `bmf_unified` |
| series | `efile_header`, `efile_orgtext`, `efile_officers`, `f1023ez` (one partition per approval year), `irs527` (Form 8871: one partition, re-dumped whole on each pull, so a new pull is a re-released partition), `revocations` (a cumulative list re-pulled whole, one row per revocation; §9) |
| mentions | `schedi`, `efile_related`, `efile_disregarded`, `efile_related_ptr`, `efile_related_corp`, `efile_affiliate_listing` and `efile_sched_c_affil` (both published by year from e-file v2_3), `irs527_related` (one pooled file) |
| cache | `meta_names`, `meta_addresses`, `meta_group_aff`, `meta_group_number`, `meta_group_return`, `ntee_crosswalk`, `address_crosswalk`, `address_geocoded` |

The kind is the `kind` column of `md_sources()` (step 2, done), with the
vocabulary in `md_source_kinds()`. `bmf_unified` is kind `seed`. An ingest
function does not choose its own update rule.

### 2a. `bmf_unified` is a snapshot that has already been folded

NCCS has already merged the monthly BMFs into one row per EIN, keeping
`first_vintage_ym`, `last_vintage_ym` and the **latest** name and address.
Loading it as one spell per EIN would claim the current name held for the EIN's
whole history, which is false for any organisation that was renamed. So:

* Load it once as a **seed**. Its spell bounds are stored as an *envelope*
  (`bounds_kind = 'envelope'`): "the EIN existed over this range and ended with
  this value", not "this value held for this range".
* From then on, ingest each monthly `bmf_active` release as a snapshot. Spells
  opened from then on are true spells (`bounds_kind = 'spell'`).
* If NCCS keeps an archive of the raw monthly files, replaying them in order
  would rebuild true spells back to the start of the archive (§9).

The e-Postcard needs no seed. Its first load opens one spell per EIN, and every
later pull extends, closes or opens spells from there.

---

## 3. Identity: four hashes

Every id is a hash of the source's own content, so anyone can recompute it from
the raw file and get the same value on any machine. Nothing a normalizer produces
goes into an id. That is what lets normalizer changes leave ids alone.

### The recipe

```
id = md5( recipe_tag  \x1f  field_1  \x1f  field_2  ... )
```

* `recipe_tag` names the recipe and its version (`name.v1`). Changing what goes
  into an id means a new tag, never a silent edit to an old one.
* Fields are joined with the ASCII unit separator `\x1f`, which cannot occur in
  the data. A plain space or `|` can, and then `"AB" + "C"` hashes the same as
  `"A" + "BC"`.
* Each text field goes through `canon()` first: UTF-8, Unicode NFC, trimmed,
  internal whitespace collapsed to one space, `NULL` mapped to `''`. **There is
  no case folding and no punctuation stripping**, so the stored string is exactly
  what the source wrote apart from whitespace. Case-insensitive matching happens
  in the normalized columns, not here.
* EINs go in as `EIN2` (`EIN-XX-XXXXXXX`), via `md_ein()`.
* Store the id as the 32-character hex string. Do not store it as a 128-bit
  integer: DuckDB's R client converts `HUGEINT` to `double` by default, which
  silently destroys the id. 64-bit truncation would fit in a `BIGINT`, but at
  roughly 200M ledger rows the chance of a collision is about 1 in 1,000. That
  is small, but not small enough for an id meant to be permanent.
* `canon()` and the hash exist **twice**, once in R and once as a DuckDB SQL
  macro. A test asserts they agree on a fixed set of test strings, including
  non-ASCII, embedded tabs and leading or trailing whitespace. Ingest uses the
  SQL macro for speed. R is for anyone verifying a row by hand.

### The four ids

| id | recipe | what it identifies |
|---|---|---|
| `name_text_id` | `md5('name.v1' ␟ canon(name_raw))` | a distinct name string, regardless of EIN or source |
| `address_text_id` | `md5('addr.v1' ␟ street ␟ unit ␟ city ␟ state ␟ zip5 ␟ zip4)`, each `canon()`ed | a distinct address as written |
| `obs_id` | depends on kind, below | one observation in the ledger |
| `release_id` | `md5('rel.v1' ␟ source ␟ version ␟ partition)` | one file (or one partition) actually read |

Text ids are deliberately **not** scoped to an EIN. "TOASTMASTERS INTERNATIONAL"
is one `name_text_id` across all 22,034 EINs that use it. It is normalized once,
and its derived columns are shared. A DBA that equals another organisation's
legal name is the same text with a different observation. Main and DBA names do
not need separate hashes: the string has one id, and its role (`legal`, `dba`,
...) lives on the observation.

### `obs_id` by kind

| kind | recipe | why |
|---|---|---|
| series | `md5('obs.v1' ␟ source ␟ record_key ␟ role)` | `record_key` is the filing id. One filing states each field once. A series with many rows per filing (`efile_officers`: one row per person) uses the mentions recipe |
| mentions | `md5('obs.v1' ␟ source ␟ record_key ␟ role ␟ occurrence)` | `record_key` is the filing id plus a hash of the row's fields, or for a pooled file with no filing id, the row hash alone. `occurrence` numbers identical rows 1, 2, 3, ... **Identical rows are real here**: two grants from one funder to one grantee in one year are two mentions, and the counter keeps them apart. Nothing depends on row order, so the ids survive re-release |
| snapshot | `md5('obs.v1' ␟ source ␟ ein ␟ role ␟ value_id ␟ first_seen)` | one id per spell. `first_seen` keeps a value that comes back (A → B → A) from colliding with its earlier spell |
| cache | `md5('obs.v1' ␟ source ␟ release_id ␟ row_hash ␟ occurrence)` | the file is the unit. A corrected re-release gets a new `release_id` and is diffed as a whole |

`value_id` is the `name_text_id` or `address_text_id`, or both for a record that
states both.

### The natural keys, confirmed

Step 2 sampled the first 2 MB of each 2022 e-file table (`efile_v3_1`), of the
2026-07 e-Postcard and revocation files, and of the other remote CSVs. The
result is the `md_record_keys()` registry, and `md_check_record_key()` reruns the
test on a whole file:

| sources | key | what the sample showed |
|---|---|---|
| 990 header, mission | `OBJECTID` | unique: one row per return. 1.5% of header EIN-years have two returns, so the amended-return rule has work to do |
| Schedule I, Schedule R Parts I–IV, officers, affiliate listing, Schedule C | `OBJECTID` + row content + occurrence | `OBJECTID` + `TABLE_ID` is unique in all seven. Rows identical in every column but `TABLE_ID` occur: 11 of 4,646 in Schedule I, up to 5 elsewhere |
| e-Postcard, monthly BMF, `bmf_unified`, NCCS metadata files | the EIN | unique |
| revocations | `ein` + `revocation_date` | unique over 11,138 rows, 247 of them reinstated |
| Form 8871 | `FORM_ID_NUMBER` | unique; EINs repeat (amendments) |
| 527 Schedule R | `ENTITY_ID` | unique |

Every e-file table carries `RETURN_AMENDED_X` and `RETURN_TIME_STAMP`, so "count
only the latest return per filer and tax year" (§9) is `max(RETURN_TIME_STAMP)`
per `(EIN2, TAX_YEAR)`.

`TABLE_ID` (`TID-000-000-NNN`) is the row's position in the return. It is kept
on each observation for tracing by hand but is **not** hashed into the id: a
parser change could renumber positions, while a row's content cannot change.

Not sampled: `f1023ez` (an xlsx cannot be range-read) and the three local files.
Their keys in the registry are marked as assumptions until checked on a full
file.

---

## 4. The ledger

### Tables

```
release            one row per file or partition read
  release_id       PK
  source, kind, version, partition      partition = tax year for series and mentions
  file_md5         per file. A set pin keeps only one combined digest today;
                   this needs per-file digests so unchanged years can be skipped
  content_vintage  as in source_vintage
  ingested_at

name_text          string dictionary, insert-only
  name_text_id     PK
  name_raw         canon() form

address_text       insert-only
  address_text_id  PK
  street_raw, unit_raw, city_raw, state, zip5, zip_plus4

obs                the ledger; rows are never deleted
  obs_id           PK
  source, kind
  ein              EIN2
  role             legal | dba | division | in_care_of | observed | mailing | ...
                   the class as asserted by the source
  name_text_id     NULL for address-only records (crosswalk spells)
  address_text_id  NULL for name-only records
  asserted_by      the filer EIN for a mention; NULL for first-party sources
  record_key       the source's natural key, as text, for tracing by hand
  period           tax year for a series or a mention; NULL for a pooled file whose
                   rows carry no year, and for snapshots and caches
  first_seen, last_seen        vintages; for a snapshot these bound the spell
  bounds_kind      spell | envelope | period
  first_release, last_release  release_ids
  retracted_in     release_id that dropped this row, else NULL
```

One `obs` row holds a name and an address together when the source wrote them
together. That **is** the pairing link (`PLAN.md` §8). It no longer depends on an
`address.name_id` that a re-ingest renumbers.

`entity_event` (revocations, terminations) is already a ledger in all but its
ids. It stays as it is in the first pass and gets `obs`-style ids in a later one.

### Counting

Rollups (§6) count from the ledger with one rule per kind:

| column | meaning | kinds |
|---|---|---|
| `n_corroborators` | distinct `asserted_by`: how many different filers wrote it. **Same meaning as today**, so the corroboration bands, the statistics cells, `min_corroborators` and the published tiers keep their meaning | mentions |
| `n_periods` | distinct years the value appeared in. For a series this **is** the corroboration: how many years the name and address stayed the same. An amended return in the same year does not add one | series; mentions whose rows carry a year |
| `n_mentions` | rows that wrote the value, counting repeats in the same file and year, and counting only each filer's latest return for a tax year (§9, decided). For a mention this is the corroboration | mentions |
| `n_spells` | snapshot spells, plus the span from `first_seen` to `last_seen` | snapshot |
| `source_mask` | which sources have ever asserted it | all |
| `role_mask`, `best_role` | which roles it has held, and the highest-ranked one | all |

`n_obs` is retired. `md_compile()`'s within-class tiebreak, which uses it today,
moves to an explicit `n_support`: `n_periods` for first-party names and
`n_mentions` for mentions. Step 6 checks that this changes no published tier
without an explanation.

---

## 5. Folding in a new release

One engine, with common first steps and then one of two update procedures. Every
`md_ingest_*()` becomes a parser: read the pinned file and return a standard frame
of `(ein, role, name_raw, street_raw, ..., asserted_by, period, record_key)`. It
then calls `md_apply_release(frame, source, version, partition)`, which does
everything below in one transaction.

**Common first steps.**

1. If `file_md5` matches a release already applied for this source and
   partition, stop. Nothing changed. For series and mentions this skips every
   year file that was not re-released.
2. `canon()` and hash the text. Insert new strings into `name_text` and
   `address_text`. Existing ids are left alone, so this step is idempotent.
3. Compute `obs_id` for every row in the frame.

**Series or mentions partition, pooled file, or cache file.**

```
new        = frame  minus  ledger rows for this source+partition      -> INSERT
kept       = frame  ∩      ledger                                      -> last_release = this
retracted  = ledger rows for this source+partition  minus  frame      -> retracted_in = this
```

A new tax year has no ledger rows yet, so it is all inserts. A re-released year
is mostly `kept`, with the late filings in `new`, and any withdrawn records are
marked rather than deleted.

For mentions, the occurrence counter makes this diff count-preserving. If a
pooled file wrote a pair three times and its next release writes it five times,
occurrences 1–3 are `kept` and 4–5 are `new`. If the next release writes it
twice, occurrence 3 is `retracted`. A pooled file is diffed as one partition, so
a re-pool that adds a year is handled the same way.

**Snapshot.** Compare the release against the **open spells**, meaning rows for
this source whose `last_release` is the previous release:

```
unchanged  = release ∩ open   on (ein, role, value_id)   -> last_seen, last_release = this
opened     = release  minus open                          -> INSERT a new spell
closed     = open  minus release                          -> left as is; the spell ends at the previous release
```

"Closed" covers both a changed value (the old spell ends and a new one opens) and
an EIN dropping off the list (the spell ends with nothing after it). Dropping off
is information in its own right, and it is kept because nothing is deleted.

Snapshot releases **must be applied in vintage order.** Applying a release older
than the newest one already applied is refused. The fix for a missed release is a
replay (below), not a back-fill.

**Two properties every source must pass, as tests:**

* **Idempotent.** Applying the same release twice changes nothing: zero rows
  inserted, updated or retracted. This replaces "run it twice and compare row
  counts" (`PAIN-POINTS.md` §6.5) with a stronger check.
* **Replay-equal.** Applying releases one at a time gives exactly the same
  ledger, compared by content hash, as rebuilding from the pinned files in order.
  This guarantees incremental updates never drift from a clean rebuild.

---

## 6. Rollups are rebuilt, never patched

Everything downstream of the ledger is a deterministic rebuild with
content-addressed ids. A rebuild produces the same ids, and nothing can be
orphaned.

| table | grain | id |
|---|---|---|
| `name` | `(ein, name_text_id)` | `md5('nv.v1' ␟ ein ␟ name_text_id)` |
| `address` | `(ein, address_text_id)` | `md5('av.v1' ␟ ein ␟ address_text_id)` |
| `entity` | `ein` | `EIN2` |
| `name_compact` | `(ein, name_key)` under one normalizer signature | — |
| `address_compact` | `(ein, street_key, city_key, state, zip5)` under one signature | — |

`name` and `address` keep the columns `md_compile()`, `md_build_stats()`, the
guards, groups and clusters read today (`variant_class`, `source`,
`n_corroborators`, `first_year`, `last_year`, ...). They are computed from the
ledger instead of written by each ingest, so everything downstream keeps working
during the change.

Things that are written at ingest today become rollup-time derivations, which is
where `PLAN.md` §7d already wanted them:

* `former`: a legal name superseded by a later legal name, from the ledger's
  periods. Today it is computed inside `md_ingest_efile_header()`.
* `active` and `layer`: from the open snapshot spells and which sources an EIN
  has. `active` = an open spell in the newest `bmf_active` release. `layer`
  follows the first-ingest-wins order step 0 encoded
  (`.md_admit_layers` in `R/md-ingest-bmf.R`).
* Guard inputs (`n_self_filers`, `filer_ein_lo/hi`): from `asserted_by`.

The `name` rollup can be larger than today's `name` table, because it keeps every
raw spelling where today's ingests keep only the most common spelling per light
key. It also merges rows across sources, which pulls the size the other way.
Measure both in step 3. Compile reads the compact tables either way, and those
stay keyed on `name_key`.

---

## 7. Normalizer changes, handled gracefully

Derived columns key on **text ids, not row ids**, and carry the signature in the
primary key:

```
name_text_derived     PK (name_text_id, normalize_signature)    every np_normalize() name column
address_text_derived  PK (address_text_id, normalize_signature) every np_normalize() address column, plus city_key
guard_key             PK (name_text_id, guard_signature)        md_guard_key() output, stored rather than recomputed per run
```

What this buys, beyond `main`'s `incremental = TRUE`:

* **No orphans, by construction.** Text ids never change, so a re-ingest cannot
  disconnect a derived row. `md_check_derived_fresh()` becomes a coverage check:
  does every text id have a row for the current signature?
* **Incremental means new strings, not re-loaded rows.** Today an incremental
  build re-derives every row a re-ingest touched, because they all got new ids.
  Here it derives only strings never seen before. A new monthly BMF adds a few
  thousand.
* **Cost scales with distinct strings, not rows.** A string shared by 22,034
  clubs is normalized once. Whether the dictionary is smaller or larger than
  today's name table depends on how many raw spellings the current light-key
  grouping hides. Measure it in step 3.
* **Signatures coexist.** A new npmatch signature is built *beside* the old one,
  not over it, so a published tier stays reproducible on its own signature until
  that signature is retired on purpose. Today a new signature means a full
  rebuild that replaces the old columns.
* **A change report before adopting a new signature.** `md_normalizer_diff(old,
  new)` reports, per derived column, how many strings got a different value,
  then how many compact groups merge or split and how many EINs that touches,
  with examples. `npmatch@ddfd967` (`"NA"` written for a missing street) is the case
  to test it on: the report should find exactly the cells the Phase 1 gate found.

### Address compaction moves onto normalized keys

`address_compact` groups on `upper(trim(street_raw))`, so "123 Main St" and "123
MAIN STREET" stay separate rows. Under this plan it groups on
`address_text_derived.street_key` plus a normalized `city_key`. The domination
rule stays as it is. Two things are needed first:

* **A city normalizer.** `np_normalize()` takes no city, so `city_key` needs one
  (SAINT/ST, FORT/FT, MOUNT/MT, punctuation). It belongs **in npmatch**, so query
  files normalize cities the same way. Until then, a matchdb-local `city_key`
  with its own signature.
* **A measurement.** Check whether `street_key` includes the unit. If it does,
  suite variants of one building stay apart. That may be right for matching but
  wrong for counting places. Report the reduction against the current table.

---

## 8. Build order

Each step ends with a check, and nothing in a later step is trusted until the
earlier check passes. The regression checks that already exist on `main` are the
acceptance test for the whole change: the **Phase 1 gate stays at three zeros**,
the **Phase 2 measurement reproduces +146 YES**, and `dev/check-build.R` stays
36 of 36.

0. **Stop the BMF ingest replacing tables. Done 2026-10-24.** It deletes and
   re-inserts its own rows in one transaction. A BMF row replaces any non-BMF
   placeholder for the same EIN. An EIN that leaves the BMF but is still
   referenced by another source's `name`, `address` or `entity_event` row is put
   back with the layer a fresh build would give it (`.md_admit_layers`).
   *Check:* three tests in `test-ingest-bmf.R`. Schedule I rows are
   byte-identical, ids included, after a BMF re-ingest and after loading a newer
   BMF (both tests fail against the old code), and the restored layer is right
   for each source.
1. **`canon()` and the id recipes**, in R and SQL. **Done 2026-10-24**
   (`R/md-identity.R`): `md_canon()`, `md_hash_id()`, `md_name_text_id()`,
   `md_address_text_id()`, `md_release_id()`, the `md_id_recipes()` registry,
   and `md_identity_macros()`, which installs the same functions as DuckDB
   macros. *Check* (`test-identity.R`): R and SQL give identical output on
   hard cases (control characters, NFC, CJK, emoji, `NULL`s) and on 3,000
   random strings, and five ids match values computed by a third md5
   implementation (`openssl`). Because the expected values are fixed constants,
   a second machine is checked just by running the tests on it.
2. **Confirm each source's natural key** and write `record_key` for each. Record
   per-file md5s in set pins. Add `kind` to `md_sources()`. **Kinds and per-file
   md5s done 2026-10-24:** every pin writes `FILES.csv` (file, size, md5) beside
   `PIN.dcf`, read by `md_source_read_files()`. Existing pins predate it; re-pin
   once to get one. **Natural keys done 2026-10-24** (`R/md-record-keys.R`,
   §3 "The natural keys, confirmed"). *Check:* `md_check_record_key()` passes on
   all 20 sampled sources. Every record-grain key is unique, and row-grain
   repeats (identical rows in one return) are counted: 0–11 per sample. It
   runs again on each full file at ingest, since a sample can disprove
   uniqueness but cannot prove it.
3. **`release`, `name_text`, `address_text`, the text-keyed derived tables.**
   **Built 2026-10-24** (`R/md-text.R`): `md_text_schema()` creates the tables
   with real primary keys, `(text_id, normalize_signature)` for the derived
   ones. `md_add_text()` adds new strings from any relation, and repeating it
   adds nothing. `md_build_text_derived()` normalizes only strings with no row
   for the current signature. `md_check_text_derived()` is the coverage check.
   Until step 4 exists, `md_build_text()` fills the dictionaries from today's
   `name` and `address` tables, and `md_text_stats()` reports rows against
   distinct strings. *Tested* (`test-text.R`): the text-keyed columns equal
   what `md_build_derived()` stores per row; a re-ingest that renumbers every
   row normalizes nothing and orphans nothing; an older signature's rows
   survive a rebuild under the new one. *Check, pending:* run `md_build_text()`,
   `md_build_text_derived()` and `md_text_stats()` on a full database to
   measure dictionary size against the 9.7M name and 18.5M address rows, and
   normalization time against the 63 minutes `md_build_derived()` takes.
4. **`obs` and `md_apply_release()`** with the update procedures. Port one source
   of each kind first: `efile_header` (series), Schedule I (mentions),
   `bmf_active` (snapshot), `address_crosswalk` (cache). *Check:* idempotent and
   replay-equal on all four, plus two synthetic runs. A snapshot run of A, A, B,
   A, then gone must give three spells with the right bounds. A pooled mentions
   file that writes a pair 3 times, then 5, then 2 must give `n_mentions` of 3,
   5 and 2.
5. **Port the remaining ingests to parsers.** Each one shrinks: its `DELETE`,
   id assignment and aggregation move into the engine.
6. **Rollups off the ledger**, then compile's tiebreak onto `n_support`, then
   address compaction onto normalized keys. Groups, keys, clusters and
   statistics rebuild unchanged on top. *Check:* the three regression checks
   above; any change to a published tier explained before republishing.
7. **`md_normalizer_diff()`.** *Check:* run across `npmatch@ddfd967`; it finds
   the cells the Phase 1 gate found.

`orgtext`, `ein_relation`, `entity_event` and `person_key` would gain from the
same pattern but are left out of the first pass. Names and addresses are what
compile reads.

---

## 9. Decisions

1. **Amended returns in mentions. Decided 2026-10-24:** when a filer has more
   than one return for a tax year, count only the mentions from the latest one.
   A series counts distinct years, so an amended return adds nothing there. A
   mention counts rows, so without this rule an amended return that re-lists the
   same grants would double them. The earlier return's rows stay in the ledger;
   they just aren't counted. This needs the filing id from step 2 to tell an
   amendment apart from a second, separate grant.
2. **`revocations` is a cumulative list, classified as `series`. Settled
   2026-10-24 by the file, open to correction.** It was described as one row
   per EIN keeping only the latest record, which would make it a snapshot. The
   file says otherwise: `md_ingest_revocations()` measured 18,909 EINs appearing
   twice and 176 three times in the 2026-07 file, each row carries its own
   revocation date, and the file has an `exemption_reinstatement_date` column
   that the ingest reads into `reinstated` events. A reinstated organisation
   stays on the list with its reinstatement date, which is the test this
   decision set; the step 2 sample has 247 such rows in 11,138. If a later pull
   shows rows disappearing, it becomes a snapshot.
3. **Case in the text id.** Keeping case (recommended) preserves exactly what the
   source wrote, at the cost of "United Way" and "UNITED WAY" being two
   dictionary entries that normalize to the same key. Folding case removes that
   duplication, but then the stored string is no longer what the source wrote.
4. **`bmf_unified` seed versus replaying monthly archives** (§2a). It depends on
   whether NCCS keeps the raw monthly files.
5. **Spell extension updates `last_seen` in place.** A purist alternative is a
   separate `(obs_id, release_id)` membership table, so the ledger is strictly
   insert-only. It is larger and slower for little gain with one maintainer.
   Recommended: update in place, and rely on replay-equality to keep it honest.
