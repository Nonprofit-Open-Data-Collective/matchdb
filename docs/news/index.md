# Changelog

## matchdb (development version)

### The normalizer comes from npnormalize

- matchdb now imports **npnormalize** for the normalizer and its
  signature, and only *suggests* npmatch. Every call to the 9 normalizer
  functions (`np_normalize()`, `np_normalize_signature()`,
  `np_stopwords()`, `np_name_freq()`, `np_token_idf()`,
  `np_name_core()`, `np_name_rules()`, `np_name_placeholder()`,
  `np_addr_freq()`) goes to npnormalize.
- The signature is unchanged, `v1-3e7b9f9d59bbb19e`, so the published
  database, bundles and tranches are all still accepted. Nothing needs
  rebuilding.
- npmatch is needed only to match, and for
  `md_reference(build_index = TRUE)`, which builds npmatch’s blocking
  index. Without npmatch the index is skipped with a message; npmatch
  builds it itself when given none.
- [`md_place_key()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_place_key.md),
  [`md_unit_id()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_place_key.md)
  and
  [`md_addr_freq()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_addr_freq.md)
  call npnormalize directly: `np_addr_key()`, `np_unit_id()` and
  `np_addr_freq()`.
  - **Before,** they looked for these functions in npmatch. With an
    npmatch that no longer holds the normalizer, they quietly fell back
    to matchdb’s own copies.
  - **The copies are removed.** They had agreed with npnormalize on
    every distinct value in the database.
  - **matchdb now requires npnormalize 0.1.1,** the first version to
    export `np_unit_id()`.

### Stamps and the workspace log record npnormalize

- Compile stamps, bundle stamps, tranche manifests, source pins and
  `source_vintage` gain `npnormalize_version` beside `npmatch_version`,
  which is now `NA` when npmatch is not installed. Old stamps stay
  readable. A database built before this gains the `source_vintage`
  column the next time a source is recorded; its old rows keep `NULL`.
- The workspace log records `npnormalize_version` and
  `npnormalize_commit`, and a change in either is a `version_change`
  row. An older `logs/runs-index.csv` is rewritten once, adding the two
  columns, the next time an action is logged.

## matchdb 0.1.1

The first tagged release, `v0.1.1`. Its number matches **npmatch
0.1.1**, the release it pairs with: both are the last versions before
the normalizer moves into the npnormalize package. Pin both, in renv or
with `@v0.1.1`, for anything that should reproduce results from before
that move.

### Pairs with

- **npmatch 0.1.1** (`npmatch (>= 0.1.1)`; `Remotes:` pins `@v0.1.1`).
- **Normalizer signature `v1-3e7b9f9d59bbb19e`.** Everything published
  so far was built with this signature, and everything matchdb reads
  checks it: the database, the four tier bundles and the parquet
  tranches.

### The published data at this release

Built on 2026-10-26 from `main` at `592b078` with npmatch `26a5910`. It
is all public at `https://nccs-efile.s3.amazonaws.com/dev/matchdb`; no
AWS account is needed.

- **`MATCHDB.duckdb`** (11.7 GB, 26 tables) is the user copy, fetched by
  [`md_fetch_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_fetch_reference.md).
  **`MATCHDB-full.duckdb`** (24.3 GB) adds the observation ledger, for
  maintainers.
- **Four tier bundles**, read by
  [`md_reference()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md):
  `active-legal` (2.74M rows), `active-observed` (2.89M),
  `unified-legal` (4.98M) and `unified-observed` (5.13M).
- **Parquet tranches**, build `2026-10-27-82c6f0cb` (108 files, 4.64
  GB). `md_fetch_tranches(spec)` downloads only the files a spec needs:
  about 1.0 GB for an active-layer spec.

### What is in this release

- **Building the database:**
  - the ingests for the BMF, NTEE, 1023-EZ, e-file headers, Schedule I,
    Schedule R, group exemptions, 527 filings, the 990-N e-Postcard,
    revocations, websites and officer name keys;
  - content-hash ids, and the append-only observation ledger with
    rollups (`dev/IDENTITY.md`);
  - the stored normalizer columns, compact tables, EIN keys, typed
    clusters, places, and the statistics cells.
- **Compiling:**
  [`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md)
  and
  [`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md).
  - A spec chooses layers, name and address classes, sources and
    corroboration.
  - The compiled frame is checked against `np_normalize()` on every
    compile.
  - Compiling reports what the spec leaves out.
- **Publishing:**
  - [`md_publish()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
    writes signed bundles, and
    [`md_reference()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
    refuses a stale or altered one;
  - [`md_publish_tranches()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish_tranches.md)
    writes the database as parquet, split by layer and class.
- **Getting data:**
  - [`md_fetch_reference()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_fetch_reference.md),
    [`md_fetch_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_fetch_reference.md)
    and
    [`md_fetch_tranches()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish_tranches.md),
    over plain HTTPS, with md5 checks;
  - [`md_tranche_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish_tranches.md),
    a connection over the downloaded files that
    [`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md),
    [`md_publish()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md),
    [`md_lookup()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_lookup.md)
    and
    [`md_cluster()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_cluster.md)
    take unchanged.
- **The workspace:**
  - one folder,
    [`md_data_root()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_data_root.md);
  - the log:
    [`md_log()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_log.md)
    and
    [`md_log_run()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_log.md),
    with `logs/runs-index.csv` append-only;
  - [`md_status()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_log.md),
    the current state, kept in `logs/state.json`;
  - `version_change` rows, written when the data build, the npmatch
    version or the normalizer changes;
  - [`md_tranches()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_tranches.md),
    [`md_tranche_manifest()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_tranches.md),
    [`md_tranche_diff()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_tranches.md)
    and
    [`md_tranches_prune()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_tranches.md),
    for seeing what is published and updating to a new build;
  - the guide,
    [`vignette("workspace")`](https://nonprofit-open-data-collective.github.io/matchdb/articles/workspace.md).
- **Looking things up:**
  [`md_lookup()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_lookup.md)
  and
  [`md_cluster()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_cluster.md).

### Checks at this release

- **Phase 1 gate:** three zeros against the frozen baseline.
- **Phase 2:** +146 YES on the 1k benchmark.
- **`check-build`:** 36 of 36.
- **Tranches:** each tier compiled from its own tranches is identical to
  its bundle.
- The logs are in `dev/verify/logs/`.
