# matchdb

An R package used to build a 'disambiguation database', an augmented version of the BMF that serves as a more expansive nonprofit directory for record linkage.

> **Status: design stage.** No code yet. The development plan is
> [`dev/PLAN.md`](dev/PLAN.md) — start there.

## What this is

A build system and distribution layer for the reference side of nonprofit record
linkage: the universe of known (EIN -> name) and (EIN -> address) observations
from every available source of truth, with provenance, normalized once, and
compiled on demand into the reference frame that
[npmatch](https://github.com/Nonprofit-Open-Data-Collective/npmatch) matches
against.

It is **not** a matching engine. Blocking, comparison, vetoes, scoring and
tiering live in `npmatch`.

## The three axes

| axis | question | selected by the user? |
|---|---|---|
| **Layer** | which EINs exist at all - active BMF, inactive BMF, 990-filer-only, 527s | yes |
| **Variant class** | which observed strings for that EIN - legal name, DBA, Schedule I alias, in-care-of | yes |
| **Derived column** | which normalization of that string - `name_key`, `street_key`, tokens | no, always built |

A **spec** names a combination of the first two. Its hash is the cache key, so
the same spec is verifiably the same reference on any machine.

## Distribution

Three artifact tiers, described in `dev/PLAN.md` §7:

1. **Compiled references** - pre-built parquet per named spec, one row per
   name/address combination. The default path; no compile cost.
2. **Atom tables** - partitioned parquet for custom specs, read with partition
   pruning and compiled locally in seconds.
3. **`MATCHDB.duckdb`** - the full relational source of truth, for maintenance
   and provenance queries.

## Related repositories

| repo | role |
|---|---|
| [npmatch](https://github.com/Nonprofit-Open-Data-Collective/npmatch) | the record-linkage engine. matchdb imports it; it depends on nothing here. |
| [pfmatch](https://github.com/Nonprofit-Open-Data-Collective/pfmatch) | 990-PF grant-recipient matching - the first consumer, and where the evidence behind the plan was gathered |
| [ef2](https://github.com/Nonprofit-Open-Data-Collective/ef2) | IRS 990 e-file processing; the model for the S3/DuckDB distribution pattern |
