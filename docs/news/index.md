<div id="main" class="col-md-9" role="main">

# Changelog

<div class="section level2">

## matchdb (development version)

<div class="section level3">

### The install instructions pin all three packages

-   **The README and `vignette("matchdb")` now pin matchdb and npmatch,
    not only npnormalize**, and `vignette("workspace")` and
    `vignette("updates")` say to pin all three when the normalizer moves
    ahead of the data. They said to install npnormalize at `6d9c669`
    (0.1.3) and matchdb and npmatch from `main` with
    `upgrade = "never"`. That stopped working when `main` moved to
    npnormalize 0.1.5 and then 0.1.6: both packages now require a newer
    npnormalize than the published data was built with, so the
    instructions gave either a failed install or a matchdb that refuses
    the data.
-   The pins are the three commits the 2026-11-01 release records in its
    `MANIFEST.json`: npnormalize `6d9c669`, npmatch `7ea7447`, matchdb
    `df7e2ce`. Installed together into an empty library, they report
    signature `v1-592912060053c4c3`, which matches the published
    bundles.
-   The pins come off once the database is rebuilt and republished under
    npnormalize 0.1.6 (`v1-d49b18cc81ab79fb`).

</div>

<div class="section level3">

### npnormalize 0.1.6: the address key has a second gate ([#35](https://github.com/Nonprofit-Open-Data-Collective/matchdb/issues/35))

-   **`md_place_key()`’s macro reads both gates.** `np_addr_key()`
    blanks on the union of `np_pattern("pobox")` and the new
    `np_pattern("mailonly")` — general delivery and military mail, a
    delivery point with no box number and no building. The macro read
    only the first and so kept those keys: the parity test failed on
    `GENERAL DELIVERY` and `PSC 1234 BOX 56`, which the fixture already
    held. The two patterns overlap by design (a `DRAWER` is in both of
    npnormalize’s vocabularies), so the macro ORs the raw strings.
-   **The `np_pattern()` wiring did its job.** `DRAWER 7` and `PO BX 3`
    are new box spellings in 0.1.6 and the macro blanked both with no
    change here, because it reads the live string. Only the gate that
    did not exist when that wiring was written had to be added, and the
    two now serve as the control in the parity test.
-   **`is_mail_only` and `mail_key` are stored address columns.**
    `mail_key` is the complement of the place key — the box plus its
    ZIP, blank for everything else — and is what a blanked box still
    says: two organizations collecting mail from the *same* box are
    likely administered by the same people. Weight it with
    `npnormalize::np_mail_freq()` before believing it; one BMF box holds
    3,626 EINs. Both are functions of the address row as a whole, which
    is why they sit beside `zip5` in the stored list.
-   **The military flag’s street branch is gone, because it cannot
    fire.** It was a hand-typed
    `^(GENERAL DELIVERY|PSC [0-9]+|CMR [0-9]+|UNIT [0-9]+ BOX)` — the
    same vocabulary npnormalize now owns. Those rows are deleted from
    `pl_addr` before `place` is built, so a place that is military mail
    no longer exists to be flagged. `flag_military_or_gd` keeps its
    `state`/`city` branches, which are matchdb’s own and still reachable
    for an on-base *street* address: the street line looks ordinary and
    only `AA`/`AE`/`AP` or an `APO`/`FPO`/`DPO` city says military,
    neither of which npnormalize ever sees. The fixture gained such an
    address so the flag keeps live coverage.
-   **matchdb now requires npnormalize 0.1.6**, the first to publish
    `np_pattern("mailonly")`.
-   **The database still is not rebuilt.** The signature is now
    `v1-d49b18cc81ab79fb`; `md_build_derived()` stamps it on the next
    pass, and the staleness guard refuses to mix signatures in one
    derived table.

</div>

<div class="section level3">

### The SQL macros take their patterns from npnormalize

-   **`md_place_key()` and `md_unit_id()` in SQL no longer hold a copy
    of npnormalize’s patterns.** The PO box gate and the suite
    designator strip are read from `npnormalize::np_pattern("pobox")`
    and `np_pattern("unit_id")` each time the macros are created, so
    upgrading npnormalize alone moves them with `np_addr_key()` and
    `np_unit_id()`. The copy had already drifted: npnormalize 0.1.5 made
    a lettered box (`PO BOX A`) a box, and the macro still keyed it as a
    building.
-   **matchdb now requires npnormalize 0.1.5**, the first to publish
    `np_pattern()`.
-   **`street_has_box` is a stored address column.** npnormalize 0.1.4
    added it to `np_normalize()`‘s output, and with it installed 26
    tests failed on `main`: a compiled frame lacked a column the
    normalizer produces. Existing `address_text_derived` tables gain the
    column on the next derive pass, empty for older signatures’ rows.
-   The parity test now covers every branch of the box pattern (lettered
    boxes, streets named for a box, a box number followed by a mail
    stop, and the rural-route, military and `GENERAL DELIVERY` lines
    npnormalize#13 is about), and a second test swaps in a stand-in
    `np_pattern()` to prove the macros read it rather than a copy.
-   **The database is not yet rebuilt** under the 0.1.5 signature
    (`v1-533f186c123357cf`); that waits for npnormalize to settle
    ([#13](https://github.com/Nonprofit-Open-Data-Collective/matchdb/issues/13)).

</div>

<div class="section level3">

### npnormalize 0.1.3: the signature moves ([#29](https://github.com/Nonprofit-Open-Data-Collective/matchdb/issues/29))

-   **matchdb now requires npnormalize 0.1.3.** Its normalizer signature
    is `v1-592912060053c4c3` (was `v1-3e7b9f9d59bbb19e`), so an install
    that would silently produce the old keys cannot happen. The database
    was rebuilt once, under 0.1.3; the 0.1.2 rebuild
    (`v1-6d90b52d8b781673`) was never published.
-   **What changed in npnormalize:**
    -   0.1.2 made `BUILDING` a unit designator, as `BLDG` already was,
        so `100 CAMPUS CENTER BUILDING 86E` keys as `100 CAMPUS CENTER`
        with unit `BLDG 86E`. This is the only change that moves
        `street_key`.
    -   0.1.3, found while measuring 0.1.2 here: a line naming several
        units keeps the most specific (`1 BETHANY RD BUILDING 1 STE 5`
        keeps `STE 5`; a mail store’s `STE 204 # 22915` keeps the box,
        `# 22915`), and the house number is a whole token (`16TH ST` has
        none; it was `16T` on street `H`).
    -   No matchdb code needed changing: `md_unit_id()` and its SQL port
        agree with npnormalize on every canonical `street_unit`.
-   **Measured on the database** (`md_normalizer_diff()`,
    `dev/verify/logs/rebuild-normalizer-2026-11-01.log`): no name column
    moved (0 of 12.8M `name` rows rekeyed). Of 12.99M address strings,
    61,016 (0.47%) changed `street_unit`, 19,981 `street_num`, 26,766
    `street_name` and 6,921 `street_key`. On the `address` table, 6,068
    of 22.0M rows are rekeyed: 1,666 street-plus-ZIP groups merge and 11
    split, touching 1,593 EINs. Shared suites (`place_unit`) fall from
    36,838 to 35,439, and shared places from 2,855 to 2,824, as
    mail-store customers are told apart by their box.
-   **Every published artifact is rebuilt and uploaded** under the new
    signature, on 2026-11-01: the database (`MATCHDB.duckdb`, 11.8 GB;
    `MATCHDB-full.duckdb`, 24.2 GB), the four tier bundles and tranche
    build `2026-11-01-67c0bd2f` (108 files, 4.53 GB). They replace the
    2026-10-26 release, which pairs with matchdb 0.1.1. Artifacts from
    before are refused by matchdb with npnormalize 0.1.3 installed, and
    the new ones are refused with older npnormalize, as the signature
    check intends.
-   **Checks on the rebuild** (`dev/verify/logs/*-2026-11-01.log`):
    -   the Phase 1 gate gives three zeros against the re-frozen
        baseline, whose 1k benchmark counts are unchanged;
    -   Phase 2 is unchanged, +146 YES;
    -   `check-build` passes 36 of 36;
    -   the four tiers keep their spec hashes, each a few hundred rows
        smaller from the merged address groups, and each tier compiled
        from the new tranches (build `2026-11-01-67c0bd2f`) is identical
        to its bundle.
-   `dev/rebuild-normalizer.R` adopts a new signature on a built
    database: derives the new signature’s columns beside the old,
    reports `md_normalizer_diff()`, and with `--install` relinks the
    derived columns and rebuilds everything downstream.
    `dev/verify/release/publish-tiers.R` republishes the four tiers and
    the tranches.
-   **npnormalize 0.1.4 moves the signature again**, to
    `v1-1179714ce1e9d31f`, and refuses this data. `DESCRIPTION` asks for
    `npnormalize (>= 0.1.3)`, so a fresh install can pick up 0.1.4.
    Until the data is rebuilt under it, install npnormalize at `6d9c669`
    (0.1.3; it has no tag) and install npmatch and matchdb with
    `upgrade = "never"`. The README and `vignette("matchdb")` say so.

</div>

<div class="section level3">

### Documentation

-   Two new articles on how the database works:
    -   `vignette("corroboration-ledger")`: where each filer’s statement
        is stored, how statements become `n_corroborators`, `n_mentions`
        and `n_periods`, how names and addresses stay paired, and what
        the guards add;
    -   `vignette("updates")`: what triggers a rebuild, pinning, folding
        a release into the ledger, adopting a new normalizer, the
        checks, publishing, and what a user sees.
-   The README and the getting-started, layers, sources, corroborators
    and workspace articles are refreshed for the 2026-11-01 build. The
    workspace article now shows a real `md_tranche_diff()` between two
    published builds. The README lists npnormalize among the related
    packages, and corrects npmatch’s row: matchdb suggests npmatch, it
    does not import it.
-   `dev/CORROBORATION-FOOTPRINT.md` proposes ways to widen what
    corroboration covers: new disclosures that carry an EIN (Schedule A
    supported organizations, Schedule N successors, more of Schedule R),
    corroboration on relations (both sides reporting, years, sources),
    and a count of independent filers beside `n_corroborators`. Nothing
    in it is built yet.

</div>

<div class="section level3">

### The normalizer comes from npnormalize

-   matchdb now imports **npnormalize** for the normalizer and its
    signature, and only *suggests* npmatch. Every call to the 9
    normalizer functions (`np_normalize()`, `np_normalize_signature()`,
    `np_stopwords()`, `np_name_freq()`, `np_token_idf()`,
    `np_name_core()`, `np_name_rules()`, `np_name_placeholder()`,
    `np_addr_freq()`) goes to npnormalize.
-   The signature is unchanged, `v1-3e7b9f9d59bbb19e`, so the published
    database, bundles and tranches are all still accepted. Nothing needs
    rebuilding.
-   npmatch is needed only to match, and for
    `md_reference(build_index = TRUE)`, which builds npmatch’s blocking
    index. Without npmatch the index is skipped with a message; npmatch
    builds it itself when given none.
-   `md_place_key()`, `md_unit_id()` and `md_addr_freq()` call
    npnormalize directly: `np_addr_key()`, `np_unit_id()` and
    `np_addr_freq()`.
    -   **Before,** they looked for these functions in npmatch. With an
        npmatch that no longer holds the normalizer, they quietly fell
        back to matchdb’s own copies.
    -   **The copies are removed.** They had agreed with npnormalize on
        every distinct value in the database.
    -   **matchdb now requires npnormalize 0.1.1,** the first version to
        export `np_unit_id()`.

</div>

<div class="section level3">

### Stamps and the workspace log record npnormalize

-   Compile stamps, bundle stamps, tranche manifests, source pins and
    `source_vintage` gain `npnormalize_version` beside
    `npmatch_version`, which is now `NA` when npmatch is not installed.
    Old stamps stay readable. A database built before this gains the
    `source_vintage` column the next time a source is recorded; its old
    rows keep `NULL`.
-   The workspace log records `npnormalize_version` and
    `npnormalize_commit`, and a change in either is a `version_change`
    row. An older `logs/runs-index.csv` is rewritten once, adding the
    two columns, the next time an action is logged.

</div>

</div>

<div class="section level2">

## matchdb 0.1.1

The first tagged release, `v0.1.1`. Its number matches **npmatch
0.1.1**, the release it pairs with: both are the last versions before
the normalizer moves into the npnormalize package. Pin both, in renv or
with `@v0.1.1`, for anything that should reproduce results from before
that move.

<div class="section level3">

### Pairs with

-   **npmatch 0.1.1** (`npmatch (>= 0.1.1)`; `Remotes:` pins `@v0.1.1`).
-   **Normalizer signature `v1-3e7b9f9d59bbb19e`.** Everything published
    so far was built with this signature, and everything matchdb reads
    checks it: the database, the four tier bundles and the parquet
    tranches.

</div>

<div class="section level3">

### The published data at this release

Built on 2026-10-26 from `main` at `592b078` with npmatch `26a5910`. It
was public at `https://nccs-efile.s3.amazonaws.com/dev/matchdb`, with no
AWS account needed, until 2026-11-01, when the npnormalize 0.1.3 rebuild
replaced it (see the development version above). Its tranche build is
still there.

-   **`MATCHDB.duckdb`** (11.7 GB, 26 tables) is the user copy, fetched
    by `md_fetch_db()`. **`MATCHDB-full.duckdb`** (24.3 GB) adds the
    observation ledger, for maintainers.
-   **Four tier bundles**, read by `md_reference()`: `active-legal`
    (2.74M rows), `active-observed` (2.89M), `unified-legal` (4.98M) and
    `unified-observed` (5.13M).
-   **Parquet tranches**, build `2026-10-27-82c6f0cb` (108 files, 4.64
    GB). `md_fetch_tranches(spec)` downloads only the files a spec
    needs: about 1.0 GB for an active-layer spec.

</div>

<div class="section level3">

### What is in this release

-   **Building the database:**
    -   the ingests for the BMF, NTEE, 1023-EZ, e-file headers, Schedule
        I, Schedule R, group exemptions, 527 filings, the 990-N
        e-Postcard, revocations, websites and officer name keys;
    -   content-hash ids, and the append-only observation ledger with
        rollups (`dev/IDENTITY.md`);
    -   the stored normalizer columns, compact tables, EIN keys, typed
        clusters, places, and the statistics cells.
-   **Compiling:** `md_spec()` and `md_compile()`.
    -   A spec chooses layers, name and address classes, sources and
        corroboration.
    -   The compiled frame is checked against `np_normalize()` on every
        compile.
    -   Compiling reports what the spec leaves out.
-   **Publishing:**
    -   `md_publish()` writes signed bundles, and `md_reference()`
        refuses a stale or altered one;
    -   `md_publish_tranches()` writes the database as parquet, split by
        layer and class.
-   **Getting data:**
    -   `md_fetch_reference()`, `md_fetch_db()` and
        `md_fetch_tranches()`, over plain HTTPS, with md5 checks;
    -   `md_tranche_db()`, a connection over the downloaded files that
        `md_compile()`, `md_publish()`, `md_lookup()` and `md_cluster()`
        take unchanged.
-   **The workspace:**
    -   one folder, `md_data_root()`;
    -   the log: `md_log()` and `md_log_run()`, with
        `logs/runs-index.csv` append-only;
    -   `md_status()`, the current state, kept in `logs/state.json`;
    -   `version_change` rows, written when the data build, the npmatch
        version or the normalizer changes;
    -   `md_tranches()`, `md_tranche_manifest()`, `md_tranche_diff()`
        and `md_tranches_prune()`, for seeing what is published and
        updating to a new build;
    -   the guide, `vignette("workspace")`.
-   **Looking things up:** `md_lookup()` and `md_cluster()`.

</div>

<div class="section level3">

### Checks at this release

-   **Phase 1 gate:** three zeros against the frozen baseline.
-   **Phase 2:** +146 YES on the 1k benchmark.
-   **`check-build`:** 36 of 36.
-   **Tranches:** each tier compiled from its own tranches is identical
    to its bundle.
-   The logs are in `dev/verify/logs/`.

</div>

</div>

</div>
