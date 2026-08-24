# Pain points from the first pass

**Running log, opened 2026-08-23.**

This build is a dry run: work the process once end to end, find where it hurts,
turn the fixes into reproducible functions, then rebuild the official version
against a process known to be robust. This file is the record of what actually
broke, so the second pass does not rediscover it.

Entries are things that **cost time or produced a wrong answer**, not things
that were merely tedious. Each says what to do about it.

---

## 1. Failures that look like success

The expensive category. Everything here produced a plausible result that was
wrong, or a silent loss.

**Columns dropped at `INSERT`.** `md_ingest_schedi()` and `md_ingest_schedr()`
compute `first_year` and `last_year` into their staging tables, and the target
`name` table has no such columns, so the `INSERT` column list omits them and
DuckDB accepts it without complaint. 1.9M observed names have no time envelope,
and the recency ranking in `REDUCTION.md` §3c cannot be applied to names at all.
**Fixed** 2026-08-23: `name` gained `first_year`/`last_year`, and
`md_ingest_schedi()`, `md_ingest_schedr()` and `md_ingest_efile_header()` were
already computing the values in their staging tables and just needed the
columns added to the `INSERT` list. Re-running the three (idempotent) backfilled
9,662,561 name rows with 3,610,319 now carrying a year envelope — every observed
and former name, only `bmf` legitimately has none, since a snapshot has no
per-row year to give. Still open: a validation that every column a staging table
computes is either inserted or explicitly discarded, so the next instance of
this is caught at ingest time rather than found by inspection.

**`f1023ez` used `mode(name_raw)` directly**, the exact non-deterministic
tiebreak `md_modal_sql()` was built to replace (see the next entry) — found
while fixing the entry above, not by the determinism check that caught the
Schedule I case originally, which is itself worth noting: the check that found
one instance did not generalize to finding a second. **Fixed** 2026-08-23,
moved onto `md_modal_sql()`.

**`mode()` is non-deterministic under ties.** Two runs of the Schedule I ingest
over byte-identical input produced address counts differing by one: a tie between
`''` and a real street flipped which side of a non-empty filter a row landed on.
DuckDB's `mode()` returns *a* most-common value, not *the* one. **Fixed** by
`md_modal_sql()`, which orders by frequency then by the value itself. The general
rule — no `mode`, `any_value`, `first`, `arg_max`, `arg_min` in an ingest — is in
`?md_modal_sql`.

**`affiliation_code` is not ordered by seniority.** Code 8 is
`GROUP-EXM-PARENT-CHURCH`, a *parent*. Reading the codes as ascending juniority
put 713 church parents on the member side of their own groups and never used them
as parents; correcting it recovered **119,819 pairs, 37% more group structure.**
The output was well-formed throughout. **Lesson:** for any coded vocabulary, read
the code book before inferring an ordering from the numbers.

**Sampling destroyed the structure being measured.** A 400,000-row sample put
name deduplication headroom at 0.2%; the full table says 15.8%. Duplicates
cluster *within* an EIN, and a random draw from 9.7M rows rarely takes two rows
for the same one. **Lesson:** sampling is valid for per-row cost, invalid for
anything about within-group structure.

**Weight-zeroing does not isolate a score term.** Scoring with
`name_geo = c(0, 1)` to obtain a "pure geography" value returned 0.900 — the
promotion *floor*, which ignores the weights — and produced a fake divergence in
the decomposition probe. Term isolation needs the floor disabled as well.
Recorded in `DECOMPOSITION.md` §7.

**A coverage figure above 100%.** The geocode ingest reported "170% of geocodes
found their address" because rows-enriched and geocodes-placed are different
quantities. A percentage over 100 is never a rounding artefact; it means the
denominator is wrong.

---

## 2. Data-format traps

**DuckDB reserved words.** `rows`, `last`, `years` are all reserved and fail as
column aliases with a bare parser error pointing at the wrong token. Cost several
round trips. **Fix:** prefix aliases (`n_rows`, `pct_last`).

**The CSV sniffer guesses the quote character wrong.** On
`address_resolved_crosswalk.csv` it inferred *no* quote character, so a street
like `"849 ALMAR AVE. STE. C, PMB 217"` split into fourteen columns against a
thirteen-column header and the read failed outright. The error text recommends
`ignore_errors=true`, which would have silently dropped every row with a comma in
its street — the rows most worth having. **Fix:** state `quote` and `escape`
explicitly on every `read_csv_auto()`; never take the sniffer's word on a file
with free-text fields.

**Two independent xlsx readers segfault rather than error.** `readxl::read_excel()`
and DuckDB's `read_xlsx()` both crash the R process on the 1023-EZ approvals file
— 47 MB compressed, **313 MB of sheet XML** over 7.2M string cells. A segfault in
a build script reads as a crash, not as unsupported input. **Fix:**
`md_xlsx_to_csv()` streams the archive directly and takes a column list.

**Upstream file naming is not consistent across years.** The IRS has published
1023-EZ approvals as `f1023ez_approvals_2014`, `f1023EZ_approvals_2017` and
`f1023ez-approvals-2020`, and the 2024 link on its own index page 404s. A
single-pattern fetch acquires nine of ten years and looks complete. **Fix:** the
downloader tries each convention; `?md_f1023ez_urls` records them.

**Column headers change case between vintages.** The 1023-EZ EIN header is `EIN`
through 2018 and `Ein` by 2023. **Fix:** `md_xlsx_to_csv()` matches
case-insensitively and writes the requested spelling.

**The same field arrives in three formats.** GEN is `155.0` in the NCCS metadata
and `0155` in the BMF; EINs arrive as `010015091`, `01-0015091`,
`EIN-01-0015091` and `ein-01-0015091`. **Fix:** `md_ein()` and explicit
normalisation before any comparison.

---

## 3. API friction

**`np_normalize()` computes everything, always**, and requires fixed column
names. Normalising a long attribute table means building a throwaway wide frame
with stub columns, then discarding half the output. Measured waste: roughly half
of a 36-minute pass. **Ask:** `fields =` and an explicit column mapping.
`DECOMPOSITION.md` §4.

**No vocabulary for what a candidate row *is*.** There is no way to tell npmatch
that a candidate belongs to a *different but affiliated* organisation, which is
the case 44% of group pairs sharing an exact legal name makes common. **Ask:**
`variant_class` and `cluster_id` in `np_fields`.

**A pin guard rejected files in the directory they arrived in.** `md_source_pin()`
requires a file under `sources/<source>/`, and the supplied crosswalks were in
`sources/address/` and `sources/ntee/`. Correct behaviour, discovered late.
**Fix:** the layout is documented in `?md_data_root`; move files on arrival.

---

## 4. Environment

**An orphaned R process held the DuckDB file lock** (twice) after its task reported
complete, blocking the next query with "File is already open". **Fix:** audit
`on.exit()` in the ingest wrappers; consider a lock-check helper. Note `pkill -f`
does not reach these on Windows -- `taskkill //PID <n> //F` does.

**Concurrent work on the same repository.** The working tree was checked out to
`main` mid-session, so the package appeared to lose eighteen files; everything was
intact on the feature branch. Nothing was lost, but the diagnosis cost time.
**Lesson:** check `git branch --show-current` before concluding that files are
missing.

---

## 5. Structural changes this pass produced

**`source_vintage` needed three dates, not one.** `fetched` alone could not
answer "is this stale?" — the BMF is published 2026-08-11 but its newest
internal vintage is 2026-07, and that fact was sitting in `build_note` as prose.
Added `content_vintage`, `content_vintage_rule` (`measured` / `declared` /
`published`) and `built`. Backfilled from the data actually loaded rather than
guessed: `bmf_unified` from the known active vintage, `schedi`/`schedr`/
`efile_header`/`f1023ez`/`efile_orgtext` from `max(last_year)` or `max(tax_year)`
in the rows already on disk, `address_crosswalk`/`address_geocoded` from their
own vintage columns. Sources with no row-level year — the local crosswalks —
are recorded `declared` from the directory version rather than left blank or
mislabelled `measured`. `built` could not be reconstructed for rows that
predate the column, so those were set to `fetched` as a stated lower bound, not
a measurement.

This is a real answer to "does what we've learned change the table structure":
yes, once, concretely, and the change was cheap because it was additive
(`ALTER TABLE ... ADD COLUMN`) rather than a rebuild.

---

## 6. Standing rules this produced

1. State `quote`/`escape` on every CSV read; never accept `ignore_errors`.
2. No tie-breaking aggregate in an ingest — use `md_modal_sql()`.
3. Read the code book before inferring meaning from coded values.
4. Sample for cost, never for within-group structure.
5. Every ingest must be idempotent and must be *tested* by running it twice and
   comparing row counts **and** a content hash.
6. A measurement that can exceed 100% has the wrong denominator.
7. Report what a load held back, not only what it wrote.
