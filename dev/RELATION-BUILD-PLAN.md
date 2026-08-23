# Building out `ein_relation` — the two structures

**Written 2026-08-22.** Companion to `GROUP-STRUCTURE-FINDINGS.md`, which says
*what the relations are worth*; this says *what is left to load and in what
order*.

`ein_relation` holds two structures that must not be merged (findings §2):

* **group structure** — `relation = 'group_member'`, sourced
  from the group exemption process. Feeds `group_id`.
* **related-entity structure** — `relation IN ('related_entity','disregarded_entity')`, sourced
  from voluntary disclosure. Feeds `related_entity_id`.
  **Never** enters `group_id` components: unioning them produces a giant
  component across the health and university sectors — 37,163 EINs before this
  build, **117,869 after**.

## Where it stands

**Queue cleared 2026-08-22.** Every source in tranches A, B and C is loaded.

```
relation           evidence                          rows    ein_a    ein_b
related_entity     schedule_r_part_ii              863,976   96,955  119,865
related_entity     schedule_r_part_iii_partnership 412,151   19,394   40,718
related_entity     schedule_r_part_iv_corporation  342,433   31,487   63,799
related_entity     irs527_schedule_r                15,891    8,300        0  (ein_b NULL by design)
related_entity     schedule_c_part_ii_a                886      157      431
disregarded_entity schedule_r_part_i_disregarded    64,103   15,603   33,327
group_member       bmf_group_exemption             439,936    3,580  439,936
group_member       efile_group_exemption_number      6,012    1,036    5,972
group_member       nccs_group_metadata_historical    2,913      709    2,913
group_member       efile_affiliate_listing           2,497      135    2,492
                                                 ---------
  related_entity     1,635,337
  group_member         451,358
  disregarded_entity    64,103
  TOTAL              2,150,798      (was 1,306,825)
```

Relation values follow the **§4a vocabulary** in `PLAN.md`. An earlier pass in
this build labelled all six non-group sources `affiliate`; that was a catch-all,
and wrong — "affiliate" means a federated chapter in sector usage, which is close
to group structure and nothing like a taxable subsidiary. §4a has the reasoning,
including why `affiliate` is now precisely defined and holds zero rows.

Derived components, for comparison with `GROUP-STRUCTURE-FINDINGS.md`:

| | before | after |
|---|---:|---:|
| `group_id` components / EINs | 3,643 / 446,492 | **3,686 / 450,150** |
| `related_entity_id` components / EINs | 33,206 / 143,145 | **41,635 / 280,582** |
| largest related-entity component | 37,163 | **117,869** |

The related-entity giant nearly quadrupled. That reinforces rather than weakens
the §2 rule: these edges must never enter `group_id`, and `related_entity_id`
needs a guard before any consumer treats a component as an organisation.

`efile_affiliate_listing` also wrote **2,880 `observed` names** onto
subordinates' own EINs - the findings §5 item, and the only source of those
names.

### Two defects surfaced by loading

* **4,133 self-loops**, all from `md_ingest_relations()` Part II. Every other
  relation source filters `ein_a = ein_b`; that one does not. One-line fix plus
  a re-run.
* **12,519 rows over 6,423 EINs have an `ein_a` not in `entity`**, all from
  `irs527_sched_r`. Expected, not a bug: 527 political organisations are not in
  the BMF-derived entity layer because `irs527` itself has not been ingested to
  `entity` yet. That ingest is the remaining gap.

## The queue — all cleared

Ordered as worked: readiness × value.

| # | source | feeds | ingest function | edges added |
|---|---|---|---|---|
| A1 | `irs527_related` — 527 Schedule R | related_entity, `ein_b` NULL | `md_ingest_irs527_related()` | 15,891 |
| A2 | `efile_header` H(c) `GroupExemptionNum` | group_member | `md_ingest_efile_group()` | 6,012 |
| B1 | `SR-P03` taxable partnerships | related_entity | `md_ingest_schedr_parts("partnership")` | 412,151 |
| B2 | `SR-P04` taxable corporations/trusts | related_entity | `md_ingest_schedr_parts("corporation")` | 342,433 |
| B3 | `SR-P01` disregarded entities | disregarded_entity | `md_ingest_schedr_parts("disregarded")` | 64,103 |
| C1 | e-file `AffiliateListing` | group_member + `observed` names | `md_ingest_affiliate_listing()` | 2,497 + 2,880 names |
| C2 | e-file `AffiliatedGroupSchedule` (Sch C) | related_entity | `md_ingest_sched_c_affil()` | 886 |

Measured EIN-resolution rates for the tranche-B counterparties: **disregarded
8.4%, partnership 5.2%, corporation 9.1%**. All comparable to the 527 case
(14.8%), all far below Part II. That rate settled the taxable/exempt question:
they stay `related_entity` with the part carried in `evidence`. Part I is the
exception and gets its own value — see §4a and `?md_ingest_schedr_parts`.

### Deliberately not loaded

`meta_group_aff` and `meta_group_return` — 95.4% null, and what they encode is
*filing behaviour* (was this org included in a group return) rather than a
relation between two EINs. Already argued in `?md_ingest_group_meta`. They stay
registered and unloaded.

## Tranche A — on disk

**A1. 527 Schedule R.** Everything needed is already established in
`?md_irs527_shape`: 62,153 rows over 8,377 EINs; the counterparty has a name and
address but no EIN, so `ein_b` stays NULL and `related_name` carries it;
`ENTITY_RELATIONSHIP` is free text with 528 distinct values, `Connected`
(54,660) and `Affiliated` (5,801) covering 97.4%. The mapping onto the
`relation` enum must be explicit and must state what it does with the tail —
`relation_raw` keeps the original either way. `fread()` segfaults on the sibling
8871 file, so use `read_csv_auto` in DuckDB or `read.csv()`.

Hard constraint from §10: the related entity's name must **not** be registered
as a `name` variant on the 527's EIN.

**A2. e-file group exemption number.** The header files are already downloaded
for `entity`/`name`/`address` but the group columns were never read. This is the
filer's *own* report of its GEN, independent of the BMF, across 2009–2024 — so
it reaches subordinates the BMF never coded and it timestamps membership, which
the BMF cannot. TY2013 alone has 13,690 filings carrying a GEN, of which 483 are
group returns.

Two cautions measured on TY2013: GEN values `0000` (48), `0001` (50) and `9999`
(11) are placeholders and must be nulled; and the field is 4-character
zero-padded on both sides, matching the BMF's form.

Parent resolution reuses the `md_ingest_relations()` rule — parents are
`affiliation_code` 6 or 8, members 7 or 9 — falling back to `gen_parent` where
the BMF has no coded parent.

## Tranche B — fetchable

All three return HTTP 206 at the standard `efile_v2_2` prefix, so they need only
a registry row and a download. Each is one `md_ingest_*` against the proven
Schedule R shape.

Settled by measurement (rates above): Parts III and IV describe related
*taxable* entities — partnerships and C-corps, mostly outside the BMF universe,
so they behave like the 527 case (`ein_b` frequently unresolvable). They are
still `related_entity` — the tie is control or ownership regardless of the
counterparty's tax status — with the part carried in `evidence`. Part I is
different in kind and gets `disregarded_entity` (§4a).

## Tranche C — requires XML extraction

Neither carries an `RDB_TABLE` in the NCCS concordance, so no published CSV
exists. Confirmed against the TY2013 `FLATXML`: both resolve to blank
`RDB_TABLE`. They are reachable from the `EFILE20xx.duckdb` extracts
(2009–2013 held locally) or from raw XML.

**C1 is the higher value of the two** and the findings doc argues why: the BMF
gives 75.2% of subordinates the *parent's* name, so a subordinate's own name is
usually absent from the reference entirely, and this roster is where it lives.
It feeds two tables — `group_member` edges *and* `observed` name variants on the
subordinates' own EINs.

**C2 is near-redundant**: 91.6% of its undirected pairs already exist as
Schedule R edges. Load it for the `evidence` tag and the §501(h) provenance, not
for coverage. It is reciprocal, so self-pairs (78 of 123 filers list their own
EIN) must be dropped.

## Rules that hold across every ingest

1. **Idempotent, keyed on source.** `DELETE FROM ein_relation WHERE source = X`
   before insert, then `md_record_vintage()`. Per PLAN §10 these are full loads,
   not incremental diffs.
2. **Direction is fixed, not doubled.** A row reads "`ein_b` is a `relation` of
   `ein_a`". Never store the inverse as well.
3. **Never a clique.** Group membership is parent-to-member, linear in group
   size. A member-to-member clique on the largest group alone emits hundreds of
   millions of pairs.
4. **`relation_raw` always keeps the source's own wording**, so the mapping onto
   the enum can be revised without re-ingesting.
5. **Counterparty names never become `name` variants** of the disclosing EIN.
6. **Report what was dropped.** Placeholder GENs, unresolved parents, orphans —
   counted and messaged, not silently absorbed.
