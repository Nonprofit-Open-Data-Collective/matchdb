# matchdb (development version)

## The staging tables have a retention rule, not a memory

* **`md_droppable_signatures()` names the derived rows nothing needs.** Derived
  columns are stored per string and per signature and nothing removes an old
  set — `md_build_text_derived()` only adds rows for the installed one — so
  every signature move leaves another ~20.8M rows (about 0.75 GB) behind. Three
  full sets had accumulated by 2026-11-02, and one of them was gone only
  because someone happened to ask about it. A signature is kept when the caller
  names it (the installed one, and the predecessor a diff was taken against) or
  when a published tier's `stamp.json` names it; everything else is reported
  with its row count.
* **`md_published_signatures()`** reads `publish/latest.json` and each tier's
  stamp, which is the guard `dev/rebuild-normalizer.R --drop-old` already
  applied inline. It is named by tier label, so a refusal can still say which
  tier is holding a signature. One definition of "published" now, in one place.
* **`dev/rebuild-normalizer.R --install` reports what is droppable**, at the
  moment the signature moves rather than months later, and the new `--prune`
  deletes it. Deleting stays opt-in: a stale set's keys are the only way to
  diff back to it without re-deriving every string, which is exactly what made
  the 0.1.8 measurement possible.

## npnormalize 0.1.8: one case taken back out of the house-number join

* **Nothing in this package changes, and nothing needed to.** 0.1.8 narrows
  `.np_hyphen_house` so a lone `N`, `S`, `E` or `W` is read as a direction
  rather than closed up into the house number. matchdb replicates the *name*
  rules in SQL — `md_guard_clean()`, `md_guard_key()`, `md_light_key()` — and
  never the street key, so no macro here mirrors the rule that moved.
  `md_place_key()` reads the derived `street_key` and picks the change up
  through a rebuild, as it did for 0.1.7.
* **The change was found by measuring 0.1.7 against this database.** With the
  0.1.7 rows staged beside the 0.1.3 ones, `md_normalizer_diff()` reported
  1,499 split address groups, which the four-release diff could not attribute.
  Re-deriving every affected street twice — once as shipped, once with the join
  replaced by identity — put all 1,499 on #16, and isolating the join over the
  22,026,817-row `address` table gave its own ledger: **7,583 EIN-level groups
  merged, 1,496 split**. Classified over the 1,499 splits the diff itself
  reported, not one differs in anything beyond its separators — 505 are the
  same raw string once every mark is stripped, 994 have keys that agree once
  their spaces are — but that is a test on strings, not a reading of addresses:
  for 20 of them it does not settle which street, `1049-38 STREET` against
  `1049 38 ST STE 400` being either a house number on an unnamed numeric street
  or one on a numbered street. `1002-E SENECA ST` keyed as `1002E SENECA ST`,
  apart from the `1002 E SENECA ST` spelling of the same door; 0.1.8 closes 39
  such groups. The remaining 1,457 are a measured limitation of any
  hyphen-based rule, recorded at `.np_hyphen_house`.
* **The floor is `npnormalize (>= 0.1.8)`** and the signature is
  `v1-5e901add4a04a5d6`.
* **The database still is not rebuilt**, and the `v1-59c6e84c5f38e9f5` rows
  staged in `name_text_derived` and `address_text_derived` are superseded
  before they were ever adopted — `name_derived` and `address_derived` were
  never relinked to them. They can be dropped once the 0.1.8 pass lands, the
  same way the 0.1.6 staging rows were.

## npnormalize 0.1.7: the split-word table the SQL key was missing

* **`md_guard_key()`'s macro applies `np_name_rules()$split_words`.** 0.1.7
  folds eleven further spellings of `FOUNDATION`, three of which are the word
  cut in two by a fixed-width line break in the filing (`FOUND ATION`,
  `FOUNDATIO N`, `FOUNDATI ON`). Those three are the only ones the macro could
  get wrong, and it did: the per-token abbreviation `CASE` folded the head of
  `FOUNDATIO N` on its own, so the SQL key read `SMITH FAMILY FOUNDATION N`
  while `np_name_core()` read `SMITH FAMILY FOUNDATION`. The rejoin now runs
  inside `md_guard_clean()`, after the clean and before the `CASE`, which is
  the order `np_name_rules()` documents.
* **The parity test did not catch it, and that is the more useful finding.**
  Its fixture held no split word, so a table that gained three entries left a
  macro silently disagreeing with the function it is tested against. The
  fixture now carries one of each split form plus a single-token misspelling —
  the single-token case exercises only the `CASE` and passed throughout — and
  `PROFOUND ATION TEST`, which must not be rejoined.
* **`md_light_key()` is deliberately left alone.** It merges spellings that
  differ only in how they are typed and leaves misspellings to the normalizer's
  derived columns, so `FOUNDATION` and `FOUNDAITON` stay apart there by design.
* **No stored column changes shape.** 0.1.7 adds no column; it moves the values
  of `street_key`, `street_num`, `street_name`, `name_key`, `name_full`,
  `name_form`, `dba_key` and `division_key`, all of which `md_build_derived()`
  already stores. `md_place_key()` reads the derived `street_key`, so the
  hyphenated house numbers 0.1.7 fixes reach the place key through a rebuild
  with no change here.
* **The database still is not rebuilt.** The signature is now
  `v1-59c6e84c5f38e9f5`; `md_build_derived()` stamps it on the next pass, and
  the staleness guard refuses to mix signatures in one derived table.


## The install instructions pin all three packages

* **The README and `vignette("matchdb")` now pin matchdb and npmatch, not only
  npnormalize**, and `vignette("workspace")` and `vignette("updates")` say to
  pin all three when the normalizer moves ahead of the data. They said to
  install npnormalize at `6d9c669` (0.1.3) and matchdb and npmatch from `main`
  with `upgrade = "never"`. That stopped working when `main` moved to
  npnormalize 0.1.5 and then 0.1.6: both packages now require a newer
  npnormalize than the published data was built with, so the instructions gave
  either a failed install or a matchdb that refuses the data.
* The pins are the three commits the 2026-11-01 release records in its
  `MANIFEST.json`: npnormalize `6d9c669`, npmatch `7ea7447`, matchdb
  `df7e2ce`. Installed together into an empty library, they report signature
  `v1-592912060053c4c3`, which matches the published bundles.
* The pins come off once the database is rebuilt and republished under
  npnormalize 0.1.7 (`v1-59c6e84c5f38e9f5`).

## npnormalize 0.1.6: the address key has a second gate (#35)

* **`md_place_key()`'s macro reads both gates.** `np_addr_key()` blanks on the
  union of `np_pattern("pobox")` and the new `np_pattern("mailonly")` — general
  delivery and military mail, a delivery point with no box number and no
  building. The macro read only the first and so kept those keys: the parity
  test failed on `GENERAL DELIVERY` and `PSC 1234 BOX 56`, which the fixture
  already held. The two patterns overlap by design (a `DRAWER` is in both of
  npnormalize's vocabularies), so the macro ORs the raw strings.
* **The `np_pattern()` wiring did its job.** `DRAWER 7` and `PO BX 3` are new
  box spellings in 0.1.6 and the macro blanked both with no change here,
  because it reads the live string. Only the gate that did not exist when that
  wiring was written had to be added, and the two now serve as the control in
  the parity test.
* **`is_mail_only` and `mail_key` are stored address columns.** `mail_key` is
  the complement of the place key — the box plus its ZIP, blank for everything
  else — and is what a blanked box still says: two organizations collecting
  mail from the *same* box are likely administered by the same people. Weight
  it with `npnormalize::np_mail_freq()` before believing it; one BMF box holds
  3,626 EINs. Both are functions of the address row as a whole, which is why
  they sit beside `zip5` in the stored list.
* **The military flag's street branch is gone, because it cannot fire.** It was
  a hand-typed `^(GENERAL DELIVERY|PSC [0-9]+|CMR [0-9]+|UNIT [0-9]+ BOX)` — the
  same vocabulary npnormalize now owns. Those rows are deleted from `pl_addr`
  before `place` is built, so a place that is military mail no longer exists to
  be flagged. `flag_military_or_gd` keeps its `state`/`city` branches, which are
  matchdb's own and still reachable for an on-base *street* address: the street
  line looks ordinary and only `AA`/`AE`/`AP` or an `APO`/`FPO`/`DPO` city says
  military, neither of which npnormalize ever sees. The fixture gained such an
  address so the flag keeps live coverage.
* **matchdb now requires npnormalize 0.1.6**, the first to publish
  `np_pattern("mailonly")`.
* **The database still is not rebuilt.** The signature is now
  `v1-d49b18cc81ab79fb`; `md_build_derived()` stamps it on the next pass, and
  the staleness guard refuses to mix signatures in one derived table.

## The SQL macros take their patterns from npnormalize

* **`md_place_key()` and `md_unit_id()` in SQL no longer hold a copy of
  npnormalize's patterns.** The PO box gate and the suite designator strip are
  read from `npnormalize::np_pattern("pobox")` and `np_pattern("unit_id")` each
  time the macros are created, so upgrading npnormalize alone moves them with
  `np_addr_key()` and `np_unit_id()`. The copy had already drifted:
  npnormalize 0.1.5 made a lettered box (`PO BOX A`) a box, and the macro still
  keyed it as a building.
* **matchdb now requires npnormalize 0.1.5**, the first to publish
  `np_pattern()`.
* **`street_has_box` is a stored address column.** npnormalize 0.1.4 added it
  to `np_normalize()`'s output, and with it installed 26 tests failed on
  `main`: a compiled frame lacked a column the normalizer produces. Existing
  `address_text_derived` tables gain the column on the next derive pass, empty
  for older signatures' rows.
* The parity test now covers every branch of the box pattern (lettered boxes,
  streets named for a box, a box number followed by a mail stop, and the
  rural-route, military and `GENERAL DELIVERY` lines npnormalize#13 is about),
  and a second test swaps in a stand-in `np_pattern()` to prove the macros
  read it rather than a copy.
* **The database is not yet rebuilt** under the 0.1.5 signature
  (`v1-533f186c123357cf`); that waits for npnormalize to settle (#13).

## npnormalize 0.1.3: the signature moves (#29)

* **matchdb now requires npnormalize 0.1.3.** Its normalizer signature is
  `v1-592912060053c4c3` (was `v1-3e7b9f9d59bbb19e`), so an install that
  would silently produce the old keys cannot happen. The database was rebuilt
  once, under 0.1.3; the 0.1.2 rebuild (`v1-6d90b52d8b781673`) was never
  published.
* **What changed in npnormalize:**
  * 0.1.2 made `BUILDING` a unit designator, as `BLDG` already was, so
    `100 CAMPUS CENTER BUILDING 86E` keys as `100 CAMPUS CENTER` with unit
    `BLDG 86E`. This is the only change that moves `street_key`.
  * 0.1.3, found while measuring 0.1.2 here: a line naming several units keeps
    the most specific (`1 BETHANY RD BUILDING 1 STE 5` keeps `STE 5`; a mail
    store's `STE 204 # 22915` keeps the box, `# 22915`), and the house number
    is a whole token (`16TH ST` has none; it was `16T` on street `H`).
  * No matchdb code needed changing: `md_unit_id()` and its SQL port agree
    with npnormalize on every canonical `street_unit`.
* **Measured on the database** (`md_normalizer_diff()`,
  `dev/verify/logs/rebuild-normalizer-2026-11-01.log`): no name column moved
  (0 of 12.8M `name` rows rekeyed). Of 12.99M address strings, 61,016 (0.47%)
  changed `street_unit`, 19,981 `street_num`, 26,766 `street_name` and 6,921
  `street_key`. On the `address` table, 6,068 of 22.0M rows are rekeyed:
  1,666 street-plus-ZIP groups merge and 11 split, touching 1,593 EINs.
  Shared suites (`place_unit`) fall from 36,838 to 35,439, and shared places
  from 2,855 to 2,824, as mail-store customers are told apart by their box.
* **Every published artifact is rebuilt and uploaded** under the new
  signature, on 2026-11-01: the database (`MATCHDB.duckdb`, 11.8 GB;
  `MATCHDB-full.duckdb`, 24.2 GB), the four tier bundles and tranche build
  `2026-11-01-67c0bd2f` (108 files, 4.53 GB). They replace the 2026-10-26
  release, which pairs with matchdb 0.1.1. Artifacts from before are refused
  by matchdb with npnormalize 0.1.3 installed, and the new ones are refused
  with older npnormalize, as the signature check intends.
* **Checks on the rebuild** (`dev/verify/logs/*-2026-11-01.log`):
  * the Phase 1 gate gives three zeros against the re-frozen baseline, whose
    1k benchmark counts are unchanged;
  * Phase 2 is unchanged, +146 YES;
  * `check-build` passes 36 of 36;
  * the four tiers keep their spec hashes, each a few hundred rows smaller
    from the merged address groups, and each tier compiled from the new
    tranches (build `2026-11-01-67c0bd2f`) is identical to its bundle.
* `dev/rebuild-normalizer.R` adopts a new signature on a built database:
  derives the new signature's columns beside the old, reports
  `md_normalizer_diff()`, and with `--install` relinks the derived columns
  and rebuilds everything downstream. `dev/verify/release/publish-tiers.R`
  republishes the four tiers and the tranches.
* **npnormalize 0.1.4 moves the signature again**, to `v1-1179714ce1e9d31f`,
  and refuses this data. `DESCRIPTION` asks for `npnormalize (>= 0.1.3)`, so a
  fresh install can pick up 0.1.4. Until the data is rebuilt under it,
  install npnormalize at `6d9c669` (0.1.3; it has no tag) and install npmatch
  and matchdb with `upgrade = "never"`. The README and
  `vignette("matchdb")` say so.

## Documentation

* Two new articles on how the database works:
  * `vignette("corroboration-ledger")`: where each filer's statement is
    stored, how statements become `n_corroborators`, `n_mentions` and
    `n_periods`, how names and addresses stay paired, and what the guards
    add;
  * `vignette("updates")`: what triggers a rebuild, pinning, folding a release
    into the ledger, adopting a new normalizer, the checks, publishing, and
    what a user sees.
* The README and the getting-started, layers, sources, corroborators and
  workspace articles are refreshed for the 2026-11-01 build. The workspace
  article now shows a real `md_tranche_diff()` between two published builds.
  The README lists npnormalize among the related packages, and corrects
  npmatch's row: matchdb suggests npmatch, it does not import it.
* `dev/CORROBORATION-FOOTPRINT.md` proposes ways to widen what corroboration
  covers: new disclosures that carry an EIN (Schedule A supported
  organizations, Schedule N successors, more of Schedule R), corroboration on
  relations (both sides reporting, years, sources), and a count of
  independent filers beside `n_corroborators`. Nothing in it is built yet.

## The normalizer comes from npnormalize

* matchdb now imports **npnormalize** for the normalizer and its signature,
  and only *suggests* npmatch. Every call to the 9 normalizer functions
  (`np_normalize()`, `np_normalize_signature()`, `np_stopwords()`,
  `np_name_freq()`, `np_token_idf()`, `np_name_core()`, `np_name_rules()`,
  `np_name_placeholder()`, `np_addr_freq()`) goes to npnormalize.
* The signature is unchanged, `v1-3e7b9f9d59bbb19e`, so the published
  database, bundles and tranches are all still accepted. Nothing needs
  rebuilding.
* npmatch is needed only to match, and for `md_reference(build_index = TRUE)`,
  which builds npmatch's blocking index. Without npmatch the index is skipped
  with a message; npmatch builds it itself when given none.
* `md_place_key()`, `md_unit_id()` and `md_addr_freq()` call npnormalize
  directly: `np_addr_key()`, `np_unit_id()` and `np_addr_freq()`.
  * **Before,** they looked for these functions in npmatch. With an npmatch
    that no longer holds the normalizer, they quietly fell back to matchdb's
    own copies.
  * **The copies are removed.** They had agreed with npnormalize on every
    distinct value in the database.
  * **matchdb now requires npnormalize 0.1.1,** the first version to export
    `np_unit_id()`.

## Stamps and the workspace log record npnormalize

* Compile stamps, bundle stamps, tranche manifests, source pins and
  `source_vintage` gain `npnormalize_version` beside `npmatch_version`, which is
  now `NA` when npmatch is not installed. Old stamps stay readable. A database
  built before this gains the `source_vintage` column the next time a source is
  recorded; its old rows keep `NULL`.
* The workspace log records `npnormalize_version` and `npnormalize_commit`,
  and a change in either is a `version_change` row. An older
  `logs/runs-index.csv` is rewritten once, adding the two columns, the next time
  an action is logged.

# matchdb 0.1.1

The first tagged release, `v0.1.1`. Its number matches **npmatch 0.1.1**, the
release it pairs with: both are the last versions before the normalizer moves
into the npnormalize package. Pin both, in renv or with `@v0.1.1`, for anything
that should reproduce results from before that move.

## Pairs with

* **npmatch 0.1.1** (`npmatch (>= 0.1.1)`; `Remotes:` pins `@v0.1.1`).
* **Normalizer signature `v1-3e7b9f9d59bbb19e`.** Everything published so far
  was built with this signature, and everything matchdb reads checks it: the
  database, the four tier bundles and the parquet tranches.

## The published data at this release

Built on 2026-10-26 from `main` at `592b078` with npmatch `26a5910`. It was
public at `https://nccs-efile.s3.amazonaws.com/dev/matchdb`, with no AWS account
needed, until 2026-11-01, when the npnormalize 0.1.3 rebuild replaced it (see
the development version above). Its tranche build is still there.

* **`MATCHDB.duckdb`** (11.7 GB, 26 tables) is the user copy, fetched by
  `md_fetch_db()`. **`MATCHDB-full.duckdb`** (24.3 GB) adds the observation
  ledger, for maintainers.
* **Four tier bundles**, read by `md_reference()`: `active-legal` (2.74M rows),
  `active-observed` (2.89M), `unified-legal` (4.98M) and `unified-observed`
  (5.13M).
* **Parquet tranches**, build `2026-10-27-82c6f0cb` (108 files, 4.64 GB).
  `md_fetch_tranches(spec)` downloads only the files a spec needs: about
  1.0 GB for an active-layer spec.

## What is in this release

* **Building the database:**
  * the ingests for the BMF, NTEE, 1023-EZ, e-file headers, Schedule I,
    Schedule R, group exemptions, 527 filings, the 990-N e-Postcard,
    revocations, websites and officer name keys;
  * content-hash ids, and the append-only observation ledger with rollups
    (`dev/IDENTITY.md`);
  * the stored normalizer columns, compact tables, EIN keys, typed clusters,
    places, and the statistics cells.
* **Compiling:** `md_spec()` and `md_compile()`.
  * A spec chooses layers, name and address classes, sources and
    corroboration.
  * The compiled frame is checked against `np_normalize()` on every compile.
  * Compiling reports what the spec leaves out.
* **Publishing:**
  * `md_publish()` writes signed bundles, and `md_reference()` refuses a stale
    or altered one;
  * `md_publish_tranches()` writes the database as parquet, split by layer and
    class.
* **Getting data:**
  * `md_fetch_reference()`, `md_fetch_db()` and `md_fetch_tranches()`, over
    plain HTTPS, with md5 checks;
  * `md_tranche_db()`, a connection over the downloaded files that
    `md_compile()`, `md_publish()`, `md_lookup()` and `md_cluster()` take
    unchanged.
* **The workspace:**
  * one folder, `md_data_root()`;
  * the log: `md_log()` and `md_log_run()`, with `logs/runs-index.csv`
    append-only;
  * `md_status()`, the current state, kept in `logs/state.json`;
  * `version_change` rows, written when the data build, the npmatch version or
    the normalizer changes;
  * `md_tranches()`, `md_tranche_manifest()`, `md_tranche_diff()` and
    `md_tranches_prune()`, for seeing what is published and updating to a new
    build;
  * the guide, `vignette("workspace")`.
* **Looking things up:** `md_lookup()` and `md_cluster()`.

## Checks at this release

* **Phase 1 gate:** three zeros against the frozen baseline.
* **Phase 2:** +146 YES on the 1k benchmark.
* **`check-build`:** 36 of 36.
* **Tranches:** each tier compiled from its own tranches is identical to its
  bundle.
* The logs are in `dev/verify/logs/`.
