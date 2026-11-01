# Expanding the corroboration footprint

**Status: proposal, 2026-11-01. Nothing here is built or measured on matchdb
yet.** The volumes and rates come from two sibling projects that already read
these disclosures, and each one names its source:

* **networked990** (`../networked990`, with its linked `gather/dev/` notes):
  NCCS e-file `v3_1`, 990 and 990-EZ, tax years 2022–2023, 2023 counts unless
  stated.
* **superstructure** (`../superstructure`, `dev/relationship-inventory.md`,
  `dev/IDENTIFIERS-AND-LINKAGE.md`, `dev/BUILD-LOG.md` Run 008): `v3_1`,
  TY2022–24, per-year counts.

Neither project's figures transfer to matchdb unchanged: the years, the filing
rules and the resolution steps all differ. Each item below ends with the
measurement matchdb would need before building it.

---

## 0. Summary

**Corroboration** is how matchdb tells a name one filer typed once apart from a
name many independent filers agree on. Today it covers one table: observed
names. The **footprint** is the set of names, addresses and relations that carry
any third-party support at all.

It can grow in three ways:

1. **More sources:** more disclosures where a filer writes another
   organization's name, and its EIN, next to each other (§2).
2. **Relations:** corroborate the relations themselves, not only names: who
   reports a tie, from both sides, and for how many years (§3).
3. **Better counting:** distinct filers are often not independent. Count
   independent ones (§4).

| proposal | adds | verdict | § |
|---|---|---|---|
| Schedule A Part I line 12g supported organizations | name, relation | **build** | 2a |
| Schedule N dissolution and disposition recipients | name, address, `successor` relation | **build** | 2b |
| Names from Schedule R Parts I, III, IV, already read for relations | name, address | **build** for Part I; **probe** III and IV | 2c |
| Affiliate-listing address and IRS name control | address, an EIN check | **build** | 2d |
| 990-PF controlled-entity transfers (`PF-P99-T51/T52`) | name, address, relation | **probe** | 2e |
| Schedule R "direct controlling entity" names | the controller's acronyms and short forms | **probe** | 2f |
| Corroboration on `ein_relation`: both sides reporting, years, sources | relation support | **build** | 3 |
| Independent corroborators: filers collapsed by family and by preparer | a second count beside `n_corroborators` | **probe, then build** | 4 |
| Signing officer and phone, paid preparer | `ein_key` kinds, not corroboration | **probe** | 5a |
| Federal Audit Clearinghouse, state charity registries | first-party names and addresses from another authority | **scope** | 5b |
| 990-PF Part XV grants resolved by pfmatch | inferred mentions | **defer**, with a rule | 6 |
| Contractors, fundraisers, books holder, Schedule L, Schedule O, Schedule H joint ventures | name-only, mostly firms and people | **reject as name sources** | 6 |

---

## 1. What corroboration covers today

* **Observed names and their addresses**, from three mention sources:
  * Schedule I Part II (`schedi`);
  * Schedule R Part II names (`efile_related`, via `md_ingest_schedr()`);
  * the group-return roster (`efile_affiliate_listing`).

  For each `(ein, light name key)` they carry:
  * `n_corroborators`, the distinct filers who wrote that name for that EIN;
  * `n_mentions`;
  * the first and last year.

  `md_spec(min_corroborators =)` filters on `n_corroborators`. Its band edges
  (1, 2, 5, 20) define the statistics cells, so **the meaning of
  `n_corroborators` is load-bearing**. Changing what it counts changes every
  spec hash and every published tier (`dev/IDENTITY.md` §4, "Counting").
* **First-party names** (BMF, return headers, 1023-EZ) count periods
  (`n_periods`) and snapshot spells instead. A name a filer keeps for ten
  years is corroborated by time, not by other filers.
* **Relations** (`ein_relation`) carry `n_obs`, first and last year, `source`
  and `evidence`. They don't carry:
  * how many distinct filers asserted a pair;
  * whether both sides did;
  * whether a second source agrees.

  The relations aren't in the ledger either (`dev/IDENTITY.md` §8).
* **Guards** (`md_guard_observed()`, `dev/OBSERVED-NAME-GUARDS.md`) flag
  corroborated-but-wrong pairs: placeholder EINs and names, the filer's own
  EIN, a group central's EIN, and fiscal-sponsor EINs written with many
  names. Any new mention source has to run through them.

The relation vocabulary (`dev/PLAN.md` §4a) has two values defined but empty:
**`successor`** and **`affiliate`** (federated chapters without a group
exemption). §2b fills the first. Nothing found here fills the second.

---

## 2. New mention sources

Each of these is a filer writing another organization's name next to that
organization's EIN. In ledger terms it is a `mentions` source with
`asserted_by` = the filer. So it fits `obs` without a schema change, and its
names enter `rollup_name` as `observed` like Schedule I.

### 2a. Schedule A Part I line 12g: supported organizations

A supporting organization lists the organizations it supports: name, EIN,
Type I / II / III and the amount of support. There is no address on the form
(superstructure marks it NOT_ON_FORM, not blank).

* **Volume:**
  * networked990: 46k rows in 2023, 99% with an EIN;
  * superstructure: 99.3% with an EIN, but 49% of raw rows are empty grid
    lines.
* **Stability:** 93.9% of 2023 "supports" pairs were also seen in 2022. 96% of
  pairs were labeled correct (networked990, `gather/dev/step4-2022-2023.md`,
  `pair-check-2023.md`).
* **What it adds:**
  * an observed name on the *supported* organization's EIN, written by a
    filer that knows it well;
  * a relation.

  Type I ("operated, supervised or controlled by") and Type II ("supervised
  or controlled in connection with") are control ties and map to
  `related_entity`. Type III ("operated in connection with") is weaker. Keep
  the type in `relation_raw` and decide the mapping separately, as for
  Schedule C.
* **Hazard:** the type is sometimes read literally and wrong. networked990's
  example is an ISOC foundation listing Sesame Workshop as Type I. It
  affects the relation, not the name.
* **Measure first:**
  * how many 12g names are not already among the EIN's names;
  * how many supported EINs gain their first corroborated (2+ filer)
    observed name.

### 2b. Schedule N: dissolution and disposition recipients

Part I lists who received the assets of an organization that liquidated or
dissolved. Part II lists recipients of a disposition of more than 25% of net
assets. Both give name, EIN, address, IRC section and fair market value.

* **Volume:**
  * networked990: 6.3k (Part I) and 2.2k (Part II) in 2023;
  * superstructure: about 7k and 2.4k a year.
* **What it adds:** the **`successor`** relation, defined and empty since
  `dev/PLAN.md` §4a. It is the tie a matcher most needs for an old record
  whose EIN has since been revoked or terminated. The successor is where the
  money went.
* **Stability doesn't apply.** A dissolution happens once, so the 40.6%
  year-over-year rate networked990 reports for successor ties measures the
  event, not the data. Corroboration here comes from two other places:
  * `entity_event`: the dissolving EIN's termination or revocation;
  * the recipient: whether it reports the transfer (Schedule R, or Part VIII
    contributions).
* **Hazard:** rows naming a person. networked990 drops them by name shape, and
  superstructure warns that the name-shape test errs both ways. Use the EIN:
  keep rows with a valid organization EIN, and flag the rest.
* **Measure first:**
  * how many dissolving EINs have an `entity_event`;
  * how many recipient EINs are in `entity`.

### 2c. Names from Schedule R Parts I, III and IV

matchdb reads these three parts for relations (`efile_disregarded`,
`efile_related_ptr`, `efile_related_corp`) and drops the names and addresses
they carry. `dev/IDENTITY.md` step 5 already noted that Part I "could become an
observed name; that is a decision for later".

* **Part I, disregarded entities** (34k in 2023, 83% with an EIN): an LLC
  whose activity is reported on the filer's own return. superstructure says
  9.5% are written under the filer's own EIN. In those rows the name is a
  division of the filer. matchdb has a variant class for that: `division`.
  * **Build:** the name goes on the disclosed EIN as `observed`, or as
    `division` when the EIN is the filer's own.
  * The guard's own-EIN rule must not flag the `division` case.
* **Parts III and IV, partnerships and taxable corporations**
  (259k and 290k a year): mostly for-profit. matchdb measured earlier that
  only 5–9% resolve into `entity` (`dev/PLAN.md` §4a), and networked990 finds
  46% of Part IV become mention-only.
  * Names attach only where the EIN is in `entity`, so the gain is small.
  * **Probe:** the count of new observed names on EINs in `entity`.

### 2d. The group roster's address and name control

`md_ingest_affiliate_listing()` reads the subordinate's EIN and name. The
roster also carries:

* **the subordinate's address**: e-file `v3_1` publishes it, and the ingest
  ignores it (`dev/IDENTITY.md` step 5). Add it as the observed address paired
  with the observed name, as for Schedule I.
* **`F9_00_AFFIL_NAME_CTRL`, the IRS name control**: the four characters the
  IRS derives from the legal name and keys the EIN on. A roster row whose name
  control doesn't fit any of the EIN's first-party names suggests a wrong
  EIN.
  * It is a guard input, `flag_name_control`, not a name.
  * networked990's field scan (§4.2) suggests the same.
  * **Measure:** the mismatch rate, and the rate of agreement with the
    existing guards.

The roster is **one filer, the central, writing about many EINs**. Each
subordinate's name has one corroborator per central, so §4 matters here.

### 2e. 990-PF transfers to and from controlled entities

`PF-P99-T51/T52` are the only 990-PF counterparty tables with a disclosed EIN,
giving name, EIN and address. They are reported by 13–19% of PF filers
(networked990's field scan; superstructure `dev/V3-1-AND-990PF-PLAN.md` §6).
matchdb reads no 990-PF table today.

* **Probe:** whether the controlled entities are in `entity`, and how many of
  their names are new.

### 2f. The direct controlling entity, named by a third party

Schedule R Part II asks each filer for the related organization's **direct
controlling entity**. matchdb stores it as written in `relation_raw` (688,328
rows, `dev/PLAN.md` §4a). Neither the filer nor the related organization is
necessarily the controller, so it is a third party's assertion about the
parent.

* **Why it matters for names:** the strings are short forms. superstructure
  finds only 4.8% match the filer's name key (`PHC`, `NSUH`, `SUTTER HLTH`), and
  networked990 resolves CommonSpirit's code `CSH` by votes from the
  organizations it controls (`R/aliases.R`). These are the acronyms "seen in
  the wild" that `dev/PLAN.md` §10 reserves `observed` for.
* **But it has no EIN.** Resolving a name to an EIN is matching, which is
  npmatch's job (`dev/PLAN.md` §4a). The resolution can be strong, though,
  without a fuzzy match:
  * the controller is almost always the filer or another Part II
    counterparty on the same return;
  * so resolve within the return first, as networked990's cascade does.
  * Only a within-return resolution would count. It is tagged
    `resolution_method = 'within_filing'` and is never mixed with disclosed
    EINs.
* **Probe:**
  * the share of controller names that resolve within the return;
  * how many of those are a name not already held by that EIN.

---

## 3. Corroborating relations

This is the largest gain for the least new data. networked990's pair table
(`R/pairs.R`; `gather/dev/step4-2022-2023.md`) shows how much of it there is:

* **79% of ties between two full-990 filers are reported by both sides;** 0.1%
  are known only from a third filer.
* Ties persist from 2022 into 2023:

  | tie kind | 2023 pairs also seen in 2022 |
  |---|---:|
  | control | 98.5% |
  | related exempt | 96.8% |
  | supports | 93.9% |
  | weak only | 87.8% |

matchdb stores each tie as a filer-to-counterparty row and can compute this.
The proposal is a `relation_support` rollup, one row per undirected EIN pair
and relation, rebuilt from `ein_relation` the way `rollup_name` is rebuilt from
`obs`. Its columns:

| column | meaning |
|---|---|
| `reported_by_a`, `reported_by_b` | years each side disclosed the tie |
| `both_report` | both sides disclosed it in at least one shared year |
| `could_report_b` | the counterparty filed a full 990 that year and so could have answered Schedule R. Without it, a missing confirmation reads as a denial |
| `n_periods` | distinct years the tie was disclosed, by anyone |
| `n_sources`, `source_mask` | Schedule R, Schedule C II-A, the roster, Schedule A 12g, GEN, Schedule N |
| `third_party` | named by neither endpoint: a Schedule R controller (§2f), or a sibling's disclosure |

Some cross-source agreement is already measured in matchdb:

* Schedule C Part II-A: 834 of 886 edges (94%) are also Schedule R Part II
  edges (`dev/PLAN.md` §4a).
* Group membership has two independent sources, the BMF GEN and the filed
  roster. Each one being "listed but missing in the other" is a finding.
  superstructure reports that GEN linked only 2.0% of operating-organization
  and fundraising-arm pairs, against 45.8% for Schedule R Part II
  (citing `pfmatch/dev/AFFILIATION-FINDINGS.md`). GEN marks siblings, not
  parents.

**Why matchdb, rather than the matcher:** pfmatch and npmatch decide what a
relation means for a match (`np_pair_links()`, `np_cluster_rollup()`). They
can only weigh one by its support if matchdb records the support. A tie
both sides report every year and a tie one Schedule O sentence implies are
the same row today. networked990's labeled precision by pair type ranges from
30% (affiliation statements) to 100% (related exempt). That range is the case
for carrying the support.

**Measure first:** `both_report` and `n_periods` over matchdb's full
`ein_relation`, by relation and source, compared with networked990's 79%.

---

## 4. Independent corroborators

`n_corroborators` counts distinct filer EINs. Distinct is not independent.
networked990 and superstructure each found the same failure modes:

* **A system's members list one another.** Every CommonSpirit member lists
  every other, which is why networked990 caps a candidate count at 10.
* **A central files for its subordinates.** The roster is one filer.
* **One preparer files for a whole system.** The same paid preparer and the
  same signing officer appear on many returns.
* **A fiscal sponsor's EIN** is written by many funders for many projects.
  `flag_multi_name` already catches this, so it isn't new.

The proposal is a second count, **`n_independent`**: distinct filer
*families*, with filers collapsed by:

1. `group_id` (group-exemption components);
2. `related_system` cluster;
3. once §5a exists, the same paid preparer EIN, or the same signing officer
   and phone.

Keep `n_corroborators` exactly as it is. The bands, the statistics cells and
the published tiers depend on it. Add `n_independent` beside it in
`rollup_name` and `relation_support`.

Making it a spec filter (`min_independent`) is a separate decision. It would
need its own band edges in the statistics cells. That moves every spec hash,
so it is a new statistics version, not a quiet change.

**Measure first:**

* how many observed names at 2+ filers fall to 1 independent family;
* whether those names are disproportionately the guard-flagged kinds;
* the Phase 2 benchmark at `min_corroborators = 2` with and without them
  (`dev/verify/phase2-measure.R`).

If almost nothing moves, record that and stop.

---

## 5. Keys and outside sources

### 5a. Signing officer, phone and paid preparer

The return's signature block (`F9-P02-T00-SIGNATURE`) holds:

* the signing officer's name, title and phone;
* the paid preparer firm's name, EIN and address, and the preparer's PTIN.

superstructure tested it on TY2023 against known related pairs
(`dev/PROFESSIONAL-SERVICES-SIGNATURE.md`):

| shared between two filers | known-related |
|---|---:|
| signing officer name and phone | 60% |
| phone alone | 43% |
| preparer PTIN | 1.65% |
| preparer firm EIN | 0.74% |

These aren't corroboration of a name. They are **`ein_key` kinds**, beside
`person`, `website` and `place`. `n_eins_sharing` already says how much to
trust a shared key (`md_build_ein_key()`).

* The officer-and-phone key belongs there.
* The preparer is too common to propose candidates, but it is the right
  collapse key for §4.

**Caveats recorded:**

* name collisions;
* switchboard numbers shared across a building;
* 60% is a floor on precision, and recall is unknown;
* groups larger than 40 were not measured.

### 5b. Outside registries

These were **not in the two sources read**. They are listed for scoping:

* **The Federal Audit Clearinghouse.** Single-audit submissions carry the
  auditee's EIN, name and address, additional EINs covered by the same
  audit, and the auditor. Recent years also carry the auditee UEI.
  * That is a first-party `series` source from a second authority.
  * It is a possible EIN-to-UEI bridge for `usaspend`, which starts from
    UEIs.
* **State charity registries** (for example the California Registry of
  Charitable Trusts, the New York Charities Bureau): EIN, registered name
  and address, from a regulator rather than the IRS.

Both would add first-party names and addresses with their own `n_periods`, not
third-party corroborators. Before anything else, check each one's terms of
use and how it publishes the data in bulk.

---

## 6. Deferred and rejected

**990-PF Part XV grants: deferred, with a rule.** About 2 million grant rows
a year, with name and address but **no EIN** (superstructure
`dev/V3-1-AND-990PF-PLAN.md` §6b). networked990 leaves them for pfmatch and
matchdb to resolve. They would be the largest mention source by far, but
every EIN on them would be one npmatch matched against a matchdb reference.
Feeding those back into matchdb as corroboration is circular: a wrong match
becomes evidence for itself next build.

If they ever come in, the rule is:

* they are **inferred**, not disclosed, recorded as their own `kind` (or a
  `role` such as `observed_inferred`);
* they keep the match tier and the matchdb build that produced them;
* they never count in `n_corroborators` or `n_independent`;
* they never enter the statistics cells of a spec that could be used to match
  them.

**Rejected as name sources:** Part VII Section B contractors, Schedule G
fundraisers, the Part VI books holder, Schedule L interested parties,
Schedule O text spans, Schedule H joint ventures and Schedule K bond issuers.

* They give a name with no EIN.
* The names are mostly firms, people or government conduits:
  * 79% of books holders are people (networked990);
  * 50–77% of Schedule L organization names fail an organization screen.
* At best they are relation evidence for a matcher to weigh.

**Not recoverable:** Schedule B contributors (redacted, except for 990-PF and
527 filers) and Schedule F foreign grantees (region only).

---

## 7. Order of work

1. **§3, relation support** over the existing `ein_relation`. No new
   ingest. It also gives §4 its family structure.
2. **§2c Part I and §2d**: names and addresses from tables already pinned and
   read. Rerun the guards; then rerun Phase 1 and Phase 2.
3. **§2a and §2b**: two new e-file tables, each a `mentions` source.
   * §2b fills `successor`.
   * Add both to `md_sources()` with pins.
   * Add parsers in `md_parse()` so they land in the ledger from the start.
4. **§4**: the probe. Build only if it moves the benchmark or the guard
   counts.
5. **§2e, §2f, §5a**: probes. Each is a short `dev/probes/` script whose
   output goes in this note before anything is built.

Every step that adds observed names changes the observed tiers. It needs a
re-frozen baseline only if Phase 1 moves; Phase 1 reads `active-legal`, which
has no observed names, so it should not.
