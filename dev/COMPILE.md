# The compile step: `md_spec()` and `md_compile()`

**Written 2026-10-22.** Code: `R/md-spec.R`, `R/md-compile.R`, `R/md-stats.R`.
Tests: `tests/testthat/test-compile.R`. This is `REDUCTION.md` section 8, step 4, and
`PLAN.md` sections 5, 6 and 8. Measured on the e-file v3_1 database.

## What it does

* `md_spec()` describes a reference. Every selection is checked against the
  frozen vocabularies, and the spec is hashed.
  * **Layers:** which EINs.
  * **Name and address classes:** which strings.
  * **Sources:** which sources' strings.
  * **Corroboration band:** for observed names.
  * **Per-class caps.**
  * **A year cutoff.**
* `md_compile()` emits npmatch's reference frame, one row per EIN × name ×
  paired address, with `np_normalize()`'s columns. It returns:
  * npmatch's own statistics, over the frame;
  * name-level statistics, summed from cells;
  * a report of what the spec emits and what it leaves out.
* `md_build_stats()` writes the per-cell tables those sums come from:
  `stat_cell`, `stat_name_cell` and `stat_token_cell`, with cells defined by
  layer × variant class × corroboration band.

## Measured

| spec | rows | EINs | SQL | with `np_normalize()` |
|---|---:|---:|---:|---:|
| `active-legal`, `sources = "bmf"` | 1,974,830 | 1,974,830 | 17 s | — |
| `active-legal`, all sources | 2,456,647 | 1,974,830 | — | — |
| `active-observed` (observed ≥ 2 filers, observed addresses) | 2,602,912 | 1,974,830 | 15 s | 371 s |

`active-observed` by name class × address class:

```
legal     mailing    2,439,495 rows   1,974,780 EINs
observed  observed     144,723         54,492
dba       mailing       18,572         12,281
observed  mailing           67             63    (no address of its own)
legal     (none)            55             50
```

**Absence**, for any active-only spec: selected EINs with a family member the
spec leaves out.

```
group_exemption   371,729 selected EINs   45,311 excluded family EINs
co_tenant         268,205                248,822
brand             119,611                219,112
related_system     59,230                 40,044
shared_website     30,782                 18,634
care_of_network     2,697                  1,208
```

This is section 8a's warning, counted. One active EIN in five has a group
sibling outside the active layer. A thin reference cannot see that sibling, and
auto-accepts against whichever member it holds.

## What changed on the way

* **A `sources` axis.**
  * **Why:** since the e-file and 1023-EZ ingests, `legal` and `mailing` are no
    longer BMF-only. The plan's Phase 1 spec, "active, legal + dba, mailing",
    emits 2.46M rows from all sources, but exactly one row per EIN with
    `sources = "bmf"`.
  * **How names are built:** they are collapsed on the fly from the raw `name`
    rows of the selected sources, by `name_compact`'s own rules. So the spelling
    is the selected sources' own.
  * **Order of operations:** each name's class is decided across all classes
    before the spec's class filter, as compaction decides it. That keeps each
    name in the one stat cell `md_build_stats()` assigned it to. A test checks
    that the cell sums equal direct computation.
* **The dba field comes from raw DBA rows.** npmatch strips FUND and FOUNDATION
  alike, so `ACME FUND` and `ACME FOUNDATION INC` share the key `ACME` and
  compact into one name. A BMF frame still carries that DBA, so the field cannot
  come from the compacted names.
* **Two slow joins.**
  * Collecting the selected addresses took 1,261 s, because a filter inside a
    `LEFT JOIN`'s `ON` clause, with `DOUBLE` and `BIGINT` ids compared, defeated
    DuckDB's hash join.
  * The final frame query had the same pattern and took 239 s.
  * Both are plain equality joins on cast ids now, and take under 10 s.

## Not done

* **`np_normalize()` is most of the cost:** 356 of 371 s for 2.6M rows. The
  stored `name_derived` and `address_derived` columns are a subset of its output
  (no `name_acro`, `name_pre`, `name_core`, `dba_key`, ...). Storing the full set
  in `md_build_derived()` would make a compile about 15 s, which is section 6c's
  target.
* **The Phase 1 gate cannot pass against this database.**
  * The frozen `REF-active.rds` was built from the 2026-01 active BMF, 1,924,822
    rows.
  * This database loaded the 2026-09 unified BMF; its active layer is 1,974,830
    EINs.
  * The normalizer has also changed since the baseline was frozen.
  * The gate needs a baseline re-frozen against the current BMF and normalizer,
    or the 2026-01 active BMF ingested as its own pinned version.
* **No caching or publishing yet.** The spec hash is the cache key, but nothing
  writes or reads a compiled bundle (`PLAN.md` section 7b, Phase 3).
