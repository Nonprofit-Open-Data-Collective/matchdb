# Guards on observed names (Schedule I, Schedule R)

2026-10-21. Code: `R/md-observed-guards.R` (`md_guard_observed()`), called at the
end of `md_ingest_schedi()`, `md_ingest_schedr()` and
`md_ingest_affiliate_listing()`. Probe: `dev/probes/probe-observed-guards.R`;
full output in `OBSERVED-NAME-GUARDS.log`. Tests:
`tests/testthat/test-observed-guards.R`.

## Why

Schedule I and Schedule R give a (name, EIN) pair written by a third party, and
both ingests loaded every pair as an `observed` alias of the written EIN with only
a 1-9 digit EIN check. networked990's resolver, checking the same pairs against
each EIN's names, found the written EIN wrong in systematic ways: the filer's own
EIN written for its grantee, a denomination's central EIN written for a
congregation, a fiscal sponsor's EIN written for its projects, `000000000`,
`SEE SCHEDULE O`. Loaded unchecked, each becomes an alias that sends future
matches to the wrong organisation.

The question for matchdb was whether `n_corroborators` (distinct filers who wrote
the pair) already screens these. **It screens most of them, but only by
discarding most of the source, and what it keeps is concentrated in the harmful
kinds.** Details below.

## What changed

Rows are **flagged, never dropped**. New columns on `name` (observed rows only):

| column | meaning |
|---|---|
| `flag_placeholder_ein` | 9 repeated digits, `123456789`, `987654321`, or below 1,000,000 (`EIN-00-0xxxxxx`; a written `0` pads to `000000000`) |
| `flag_placeholder_name` | npmatch's rule, `npmatch::np_name_placeholder()`: `SEE SCHEDULE O`, `SEE ATTACHED`, `VARIOUS`, `N/A`, `NONE`, `SAME AS ABOVE`, blank, no letters; not when the name is consistent with the EIN's own names (`SEE` for Social and Environmental Entrepreneurs) |
| `flag_own_ein` | only the EIN itself wrote this name for its EIN, and the name is inconsistent with its names |
| `flag_group_central` | EIN has BMF affiliation code 6 or 8, and the name shares no non-denomination word with the central's names, is not equal to one, and is not its acronym or abbreviation |
| `flag_multi_name` | EIN was written on others' Schedule I for 5+ names inconsistent with its own, by 2+ filers, and this row is one of them. EIN-level: `entity.multi_name_ein` |
| `name_ein_consistent` | shares a distinctive word (3+ chars, on ≤2,000 EINs' names) or any two 3+ char words with a first-party name, equals one (spaces ignored), or is its acronym / long prefix / abbreviation. `NA` when the EIN has no first-party name |
| `guard_any` | any `flag_*`. The spec filter is `NOT guard_any` |
| `n_self_filers`, `filer_ein_lo`, `filer_ein_hi` | captured at ingest: filers who wrote their own EIN; the range of the other filers (2+ filers exactly when `lo <> hi`) |

First-party names are `legal`, `dba`, `division` and `former` rows from any
source (BMF, return headers, 1023-EZ). `md_guard_observed()` is re-runnable and
idempotent; re-run it after any ingest that adds first-party names.

Placeholder names use **npmatch's** rule, so matchdb and the matcher agree on what
is no name. It runs in R on the distinct observed strings (about 1.9M; its
cleaning step has no SQL counterpart) and is joined back. It replaced a copy of
networked990's rule, whose "no two letters in a row" test flagged real
organisations (`1N10 INC`, `S H A R E INC`, `4-H`). The word lists (`NAME_STOP`,
`NAME_ABBR`, `DENOM_WORDS`) and abbreviation rules are still **copied** from
networked990 `R/names.R`. npmatch does not export a denomination list, and its
`abbrev` list differs from networked990's.

Also fixed on the way: `md_ingest_bmf()` created `name` without
`first_year`/`last_year`, which every later ingest inserts into, so **a fresh
build failed at the return-header ingest**. The BMF ingest now creates both
columns (NULL).

## Measured

Probe database: BMF unified (2026-07), return headers, Schedule I and Schedule R
2009-2024 (EFILE v2_3). 1,722,804 Schedule I aliases and 186,463 Schedule R
aliases, matching the counts in the ingest documentation.

### Rows flagged, by n_corroborators

Schedule I:

| guard | rows | 1 filer | 2-4 | 5-19 | 20+ | % with 2+ |
|---|---:|---:|---:|---:|---:|---:|
| placeholder EIN | 13,288 | 13,034 | 250 | 4 | 0 | 1.9 |
| placeholder name | 147 | 140 | 5 | 2 | 0 | 4.8 |
| own EIN | 5,717 | 5,717 | 0 | 0 | 0 | 0.0 |
| group central | 12,401 | 11,469 | 846 | 82 | 4 | 7.5 |
| multi-name | 51,176 | 47,097 | 3,476 | 555 | 48 | 8.0 |
| **any guard** | **71,572** | 67,010 | 3,924 | 589 | 49 | **6.4** |
| name inconsistent (not a guard) | 179,553 | 170,781 | 7,773 | 947 | 52 | 4.9 |
| no first-party names to compare | 423,257 | 387,647 | 31,343 | 4,004 | 263 | 8.4 |
| all rows | 1,722,804 | 1,339,769 | 276,766 | 95,735 | 10,534 | 22.2 |

Schedule R:

| guard | rows | 1 filer | 2-4 | 5-19 | 20+ | % with 2+ |
|---|---:|---:|---:|---:|---:|---:|
| placeholder EIN | 694 | 599 | 80 | 14 | 1 | 13.7 |
| placeholder name | 53 | 51 | 2 | 0 | 0 | 3.8 |
| own EIN | 592 | 592 | 0 | 0 | 0 | 0.0 |
| group central | 235 | 201 | 26 | 7 | 1 | 14.5 |
| multi-name | 580 | 468 | 88 | 12 | 12 | 19.3 |
| **any guard** | **2,004** | 1,775 | 184 | 31 | 14 | **11.4** |
| name inconsistent (not a guard) | 5,331 | 4,412 | 657 | 195 | 67 | 17.2 |
| no first-party names to compare | 24,120 | 18,845 | 4,095 | 927 | 253 | 21.9 |
| all rows | 186,463 | 124,272 | 35,084 | 17,584 | 9,523 | 33.4 |

Overlap: 11,141 Schedule I rows raise two or more guards (mostly group central
and multi-name together, on the same denominational EINs).

3,409 EINs are multi-name; 226 of them are also group centrals.

### Does corroboration already screen them?

Flagged rows are far less corroborated than rows in general (6.4% vs 22.2% with
two or more filers on Schedule I; 11.4% vs 33.4% on Schedule R). So a
`min_corroborators = 2` spec drops most of them. That is not a screen:

| | Schedule I | Schedule R |
|---|---:|---:|
| rows kept at `min_corroborators = 2` | 383,035 | 62,191 |
| ... of which flagged | 4,562 | 229 |
| ... of which name-inconsistent | 8,772 | 919 |
| rows dropped at `min_corroborators = 2` | 1,339,769 (78%) | 124,272 (67%) |
| ... of which unflagged | 1,272,759 | 122,497 |

1. **It costs most of the source.** It removes 1.27M unflagged Schedule I
   aliases to remove 67K flagged ones. `NOT guard_any` removes the 72K and keeps
   the 1.27M single-filer rows, which is where the brand names that Schedule I
   exists to supply mostly live.
2. **What it keeps is the systematic kind.** A habit repeats across filers. Of
   the flagged rows a 2-filer floor keeps, 932 are group-central rows (congregations
   on the PC(USA), USCCB, Assemblies of God, ELCA EINs: `FIRST PRESBYTERIAN
   CHURCH` written by 32 filers for the PC(USA) EIN, `CATHOLIC CHARITIES` by 21 for
   the USCCB's) and most of the rest are multi-name rows. Placeholder EINs survive
   too: `EIN-99-9999999` carries `EMPATH ... DIVISION INC` from 12 filers.
3. **Own-EIN errors are the one kind corroboration does catch**, by construction:
   a filer's own EIN written for its grantee is not repeated by anyone else. 8,139
   Schedule I names were written by a filer under its own EIN; 5,809 are
   inconsistent with its names; only 92 of those were also written by another
   filer, and those are excluded from the flag (an affiliate listing itself under
   a name its siblings also use). On Schedule R the same holds: 696 inconsistent,
   104 corroborated.

## Known limits

- **Multi-name catches more than fiscal sponsors.** Tides Center, Community
  Foundation of the Ozarks, Charity Navigator, Candid and Brighter Bites are
  there, but so are the USCCB (3,211 flagged names), the Methodist GCFA,
  universities (departments, centres, chapters) and state governments. For
  aliasing the flag is right either way - a name unlike the EIN's own is not its
  alias - which is why the column is `flag_multi_name`, not "fiscal sponsor".
  networked990 keeps the same table and asks for more before calling an EIN a
  fiscal sponsor.
- **A wrong first-party name makes right rows look wrong.** `EIN-74-6000203` is
  the University of Texas at Austin's EIN but its BMF name is `THETA TAU` (a
  chapter's); `UNIVERSITY OF TEXAS AT AUSTIN`, written by 251 filers, is flagged
  multi-name. 60 multi-name rows have 20+ corroborators and are mostly this kind.
  A spec that wants them back can keep `flag_multi_name AND n_corroborators >= 20`.
- **Renames and acronyms that drop stop words.** `CRU` (Campus Crusade for
  Christ's current name, 77 filers) and `EHDOC` (initials include the stop word
  `CORPORATION`) are flagged group-central.
- **423,257 Schedule I rows have no first-party name to compare** (277,627
  recipient EINs are known only from Schedule I). Only the placeholder guards can
  judge them; `name_ein_consistent` is `NA`.
- **`name_ein_consistent = FALSE` is not a guard.** Its most corroborated cases
  are Schedule R properties and renamed subsidiaries (`Mercy Court` under
  `MERCY PROPERTIES ARIZONA`, 95 filers). It is a column for specs and audits.
- **`sponsor_min_filers` above 2 is treated as 2**: rows keep a filer range, not
  a filer set.
- The affiliate-listing ingest runs the guards, but was not measured (no extract
  in the probe).

## Not done (follow-ups)

- **`md_build_compact()` merges observed rows into `name_compact` and drops the
  flags.** Until it filters on or carries `guard_any`, flagged rows reach the
  compacted reference as ordinary observed names.
- The spec filter (`NOT guard_any`) is not wired into a spec or into npmatch's
  `np_fields`.
- **matchdb's derived tables are stale.** npmatch now adds `name_core` and
  `name_placeholder` to `np_normalize()` (merged as npmatch PR #13, `953994d`), which
  changes the normalizer signature, so `md_check_derived_fresh()` will report
  `name_derived` stale. They were not rebuilt here. Once rebuilt,
  `name_placeholder` will match `flag_placeholder_name` before the
  consistent-name exemption.
- matchdb now calls `npmatch::np_name_placeholder()`, which is on npmatch `main`
  from PR #13. matchdb's DESCRIPTION does not yet require that npmatch version.
