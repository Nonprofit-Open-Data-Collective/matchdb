# Places: what matchdb should compute about shared addresses

**Status: built, 2026-10-26. Tested on fixtures, and against npmatch `main`
(`26a5910`, signature `v1-3e7b9f9d59bbb19e`), which merged `fix/address-class`
in its PR #18. Every parity test now runs and passes (674 checks, none
skipped). The full-database checks in §7 are pending.**

**What installing npmatch `26a5910` showed (2026-10-26):**
* **Normalizer diff.** `md_normalizer_diff()` on a sample database built from
  the S3 samples (37,029 names, 30,527 addresses), `v1-6dcb…` → `v1-3e7b…`:
  * **Names:** none changed.
  * **Addresses:** `street_key` changed on 585 (1.9%), close to npmatch's 1.78%
    on the full BMF. 3,478 (11.4%) gained a `street_unit_id`.
  * **Rows:** 759 address rows were rekeyed, 4 address groups merged, and 4
    EINs regrouped.
* **Parsing.** "1 HARDY RD PMB 173" now keys as "1 HARDY RD" with unit PMB
  173, and "10 OLDE CENTURY FARM RD" is no longer cut at "FA".
* **The second address line works end to end:** a suite there lands in
  `street_unit_id`, and a PO box there stays out of the street.
* **Integration.** `md_addr_freq()` calls npmatch's exported `np_addr_freq()`.
  The place key, suite id and light key equal npmatch's own functions.
* **Consequence:** bundles stamped `v1-6dcb…`, which includes the four
  published tiers, are refused by `md_reference()` under this npmatch until
  they are republished, and the Phase 1 baseline must be re-frozen on the new
  signature.

This note answers npmatch's `dev/MATCHDB-ADDRESS-UNIQUENESS.md` (branch
`fix/address-class`, commits `4bc7fa7`, `9337d75`, `f8229b6`). It covers what
matchdb has to normalize and what features it has to engineer so that the
matching side knows, for any address:

* **how crowded it is**: how many organisations report it, and in how many
  suites;
* **what kind of place it is**: the place-type labels npmatch introduced.

Unless stated otherwise, numbers are npmatch's, measured on the 1.92M-row
unified BMF.

---

## 1. What npmatch now does, and what it asks of matchdb

npmatch's `np_addr_freq()` counts, over whatever reference frame it is given:
records per address, records per address and suite, and distinct suites per
address. It then labels every address that more than one record shares:

| label | rule (`.np_addr_class`, defaults) | what the address is | what separates two candidates there |
|---|---|---|---|
| `single` | 1 record | an ordinary address (88% of addresses; absent from the table) | the address itself |
| `cluster` | 2–9 records | an org with its foundation, auxiliary or PTO | the name |
| `shared` | ≥ 10 records, names spread | a fiscal sponsor, registered agent or accountant (501 SILVERSIDE RD: 1,933 records, 1,931 names) | the name; the address says nothing |
| `building` | ≥ 10 records, ≥ 2 recorded suites, suite coverage ≥ 0.5 | a multi-tenant office building | the suite |
| `federated` | ≥ 10 records, top name share ≥ 0.5 | a national office its chapters all file from (3700 GRAND AVE: 5,965 records, 45 names) | the chapter number (`name_nums`) |

Over the BMF that gives 1,188 federated addresses (60,064 records), 1,319
shared (29,910), 1,910 buildings (36,327) and 134,212 clusters. `np_compare()`
carries the label to every candidate pair and to the reviewer. The suite credit
in scoring fires only at a `building` whose suite is not itself crowded.

The note's own measurement settles what the labels are **for**. Damping the
street credit at crowded addresses changes not one decision over 304,274
labelled pairs. The labels change routing and review, not scores. That makes
their **accuracy** what matters, and accuracy is where matchdb can help.

What npmatch asks of matchdb (its §3–§8):

1. **A precomputed table, keyed exactly as npmatch keys addresses.** Today the
   counts are computed per run, from whatever frame is passed, so a state
   partition or a shard silently under-counts every shared address.
2. **The evidence columns, not just the label**, so npmatch can re-derive the
   label under different thresholds without a rebuild.
3. **Signals only matchdb has:** group-exemption structure, occupant churn
   across vintages, geocode-based building ids, and the non-building
   addresses: private mailboxes (CMRA), care-of addresses, bank trust
   departments.
4. **A normalizer-signature stamp**, refused on mismatch, as the cached
   `name_key` artifacts are.

---

## 2. What matchdb has today, and where it falls short

| matchdb today | the gap |
|---|---|
| `address_derived` / `address_text_derived` store npmatch's `street_key`, `street_unit`, `is_po_box` | no `street_unit_id`, the identifier npmatch compares suites on ("STE D-2" → `D2`). It arrives with npmatch's `fix/address-class`; `.md_derived_address_cols` must add it, and the test that checks coverage will fail until it does |
| the normalizer is called with `street`, `zip5`, `zip_plus4`, `state` | the `unit` column is never passed, though `np_normalize()` reads it when the street line names no suite, and the ledger already has a `unit_raw` slot. No parser fills it |
| Schedule I and R parsers join address lines 1 and 2 into `street_raw` | line 2 holds a suite, a PO box or a building name. Joined, "103 MAINE AVENUE" + "PO BOX 1358" becomes one street, so the PO box lands in `street_key`. Measured: 66 of 4,646 Schedule I rows (1.4%) in the 2022 sample fill line 2 |
| `ein_key` kind `place` = `street_key \| zip5` from `address_compact` | (1) the separator is `\|`, npmatch's is a space; (2) PO boxes are counted, which npmatch excludes; (3) every address class counts as an occupant (historical spells, and Schedule I addresses a third party wrote), where npmatch counts reference records |
| `address_compact` groups on `street_key`, city key, state, ZIP | npmatch's address is `street_key` + ZIP only. Fine for counting places, but not the join key the matching side uses |
| `co_tenant` clusters: every place shared by 2 to `max_cotenants` EINs | blind to place type: a small fiscal sponsor or a care-of accountant forms a "co-tenant" family |
| `entity.group_exemption_number`, `affiliation_code`; `entity_group` | not used to characterise a place |
| `care_of_network` clusters, with agent detection (bank, trust company, CPA, law firm) | not used to label a place |
| the ledger holds every EIN's addresses per filing year (990 headers), per spell (address crosswalk) and per monthly release (BMF, e-Postcard) | no occupancy history is computed from it |
| `address.lat`, `lon`, `geocode_type`: 1.78M of 3.44M rows are rooftop (`PointAddress`) | no building id |

---

## 3. Normalization: take the keys from npmatch, never re-derive them

The light key showed what keeping two implementations in step costs. Here the
keys are already computed by npmatch's own function and stored per string, so
matchdb should **store and join on npmatch's output** and port nothing to SQL.

1. **Add `street_unit_id`** to `.md_derived_address_cols` when npmatch merges
   `fix/address-class`. That merge moves the signature twice (`v1-cdea…`, then
   `v1-77a3…`). Run `md_normalizer_diff()` before adopting it: npmatch
   measured `street_key` changing on 34,280 BMF rows.
2. **Pass `unit_raw` to the normalizer as `unit`** in `md_build_text_derived()`
   and `md_build_derived()`.
3. **Keep the second address line separate.** Parsers write line 1 to
   `street_raw` and line 2 to `unit_raw`, never joined. This covers Schedule I,
   Schedule R, the affiliate listing, the e-Postcard (`organization_address_line_2`,
   empty in the 2026-07 sample but present in the layout) and Form 8871.
   npmatch then decides what line 2 is: a suite is used, and "PO BOX 1358" or
   "2 Andrews Road" is ignored instead of polluting the street. The 990 header
   publishes one line only: 236 of 3,267 rows (7.2%) name their suite inline,
   which the normalizer already extracts.
4. **One place key, npmatch's.** `place_key` = `street_key` + `" "` + `zip5`;
   empty for a PO box, which is labelled, not counted. `unit_key` =
   `place_key` + `"|"` + `street_unit_id`. Ask npmatch to **export**
   `np_addr_key()` (today `.np_addr_key()`, internal), so matchdb calls it
   rather than copying its PO-box pattern. Until then, take PO boxes from the
   stored `is_po_box`, and add a parity test against npmatch's internal function
   like the light key's.
5. **Stamp everything with the signature.** Place tables are rebuilt per
   signature. That is cheap, because derived columns are keyed on text and
   signature (Phase 5 step 3), and `md_normalizer_diff()` can grow a "places
   that change label" section.

---

## 4. Who counts as an occupant

This decision moves every count, and npmatch's note asks for both populations.

* **Occupants** are EINs whose **own current address** is the place: the BMF
  mailing address, the latest 990-header address, the e-Postcard address.
  Third-party addresses (Schedule I and R, the affiliate listing) are not
  occupancy: a grantmaker writing a grantee's address says nothing about who
  else files from it. Historical spells are not current occupancy, but they
  feed churn (§5).
* **Count EINs and records both.** npmatch counts *reference rows*, and a
  compiled tier has one row per EIN per name and address, so its record counts
  are inflated relative to EINs. matchdb publishes `n_eins` from the database,
  and per tier the counts over exactly the tier's rows (§6).
* **Count per layer.** One row per `(place_key, layer)`, the same device as
  `ein_key_layer`: layers partition EINs, so active-only, unified, or any
  selection is an exact sum. Counting defunct organisations inflates every
  threshold, so the consumer has to be able to leave them out.

---

## 5. Feature engineering

### 5a. `place`: one row per shared place

Only places with two or more occupants: a lookup miss means one occupant, which
is 88% of addresses.

| column | from | answers |
|---|---|---|
| `place_key` | §3 | the join key |
| `n_eins`, plus `place_layer` (`place_key`, `layer`, `n_eins`) | occupants (§4) | how crowded, in any population |
| `n_name_keys`, `top_name_share` | the occupants' legal `name_key` (`name_compact`) | federated (one name) or shared (many) |
| `n_units`, `max_eins_per_unit`, `n_eins_with_unit`, `unit_coverage` | `street_unit_id` | building, or a mail drop, or simply unrecorded suites. At 1,601 BMF addresses with 10+ records no record names a suite at all, so coverage has to travel with the unit count |
| `n_pmb_units`, `pmb_share` | `street_unit` designator `PMB` | a private-mailbox store (CMRA) that looks like a building and is not one |
| `n_group_exemptions`, `share_in_largest_group`, `has_group_central` | `entity.group_exemption_number`, `entity_group` | a federated office confirmed directly, without inferring it from names |
| `n_care_of_agents`, `care_of_agent_share` | occupants' in-care-of names, with the agent detection `care_of_network` already uses | an accountant's, lawyer's or bank trust department's address |
| `first_year`, `last_year`, `n_eins_ever`, `churn` | occupancy by year: 990-header filing years, crosswalk spells, monthly BMF and e-Postcard spells | an agent (occupants turn over every year) or a building (stable for a decade). Only matchdb holds the history |
| `building_id`, `n_place_keys_in_building` | rooftop geocodes (§5c) | one building written two ways |
| `place_class`, `place_flags`, `class_rule` | §5b | the labels |
| `normalize_signature` | | the stamp |

### 5b. Labels: npmatch's rule for the class, matchdb's evidence for the flags

* **`place_class`** is npmatch's four labels (`cluster`, `shared`, `building`,
  `federated`), computed with **npmatch's own rule and thresholds**
  (`share_min = 10`, `unit_coverage_min = 0.5`, top name share ≥ 0.5). If
  npmatch exports the rule (`np_addr_class()`), matchdb calls it; until then, a
  parity test. Both sides must agree on what "federated" means, or the review
  note and the precomputed table contradict each other.
* **`place_flags`** carries what only matchdb can see, without overriding the
  class. Each flag is evidence npmatch can act on or ignore:

| flag | rule (proposed; thresholds to be measured) |
|---|---|
| `po_box` | the address is a box (labelled, never counted) |
| `cmra` | `pmb_share ≥ 0.5` of the recorded suites: a mailbox store, so a PMB match earns no suite credit |
| `care_of` | `street_key` begins `C O`, or `care_of_agent_share ≥ 0.5` |
| `bank_trust` | care-of agents that are banks or trust companies, or a mail-code pseudo-suite (`10 S DEARBORN IL1 0111`) |
| `group_confirmed` | `share_in_largest_group ≥ 0.5`: a federated office confirmed by the IRS's own group ruling |
| `agent_churn` | high turnover across years: the occupants are clients, not tenants |
| `military_or_gd` | APO, FPO, DPO, general delivery |

* **`class_rule`** names the rule version, so a change of thresholds is
  visible in the artifact, just as the signature makes a normalizer change
  visible.

### 5c. Building ids from rooftop geocodes

Only `geocode_type = 'PointAddress'` rows (1.78M of 3.44M). A ZIP or street
centroid would merge a whole town. Cluster points within a small radius (to be
measured; start near 15 m) into a `building_id`. Then `127 FILMORE LN`,
`127 FILLMORE LANE` and `127 FILMORE LN STE 320` are one building: a stronger
key than string equality, and the only one that catches a misspelt street.
Carry it as evidence beside `place_key`, not as a replacement: a geocoder error
must not merge two real addresses silently.

### 5d. `place_unit`: one row per shared suite

`place_key`, `street_unit_id`, `n_eins`, the per-layer counts, `n_name_keys`.
This is what tells a real tenant's suite from a sponsor's suite shared by many.

---

## 6. How the matching side gets it

* **In every published bundle**, an `addr_freq.parquet` computed over **exactly
  the tier's reference rows**, in the shape `np_addr_freq()` returns, stamped
  with the spec hash and the signature like `name_freq`. This removes npmatch's
  slice footgun: a run against a state partition reads the whole tier's counts.
  `md_reference()` returns it as `r$addr_freq`. npmatch adds the small
  `np_addr_freq_from_table()` constructor its note proposes, and nothing in its
  scoring path changes.
* **The evidence and flags** (`place`, `place_layer`, `place_unit`) ship as a
  layer-keyed sidecar, like `ein_key_layer`. The tier's own counts decide the
  class; the flags add what the tier cannot see.
* **`co_tenant` clusters** use the class: a co-tenant family only at a
  `cluster` place without `care_of`, `cmra` or `agent_churn`.

---

## 7. Build order

Each step ends with a check.

1. **Unit plumbing.** Parsers keep line 2 as `unit_raw`; the normalizer gets
   `unit`; `street_unit_id` is stored once npmatch merges `fix/address-class`.
   *Check:* the Schedule I sample's line-2 rows (suites in `street_unit_id`,
   PO boxes and building names kept out of `street_key`); the step 6 rollup
   parity test still holds where line 2 is empty.
   **Built.**
   * Schedule I, Schedule R Part II, the affiliate listing and the e-Postcard
     write line 2 to `unit_raw`.
   * Both derive paths pass it to `np_normalize()` as `unit`. The installed
     npmatch (`ddfd967`) ignores the column; `fix/address-class` reads it.
   * The stored address columns follow npmatch's output (`.md_address_cols()`),
     so `street_unit_id` is stored as soon as npmatch produces it. A derived
     table built earlier gains the column instead of failing.
   *Tested:* "93 COTTAGE STREET" + "SUITE 1" and "103 MAINE AVENUE" + "PO BOX
   1358" stay as separate street and unit; the rollup parity test still holds.
   *Pending:* suites landing in `street_unit_id` needs the new npmatch.
2. **Place key and parity.** `place_key` and `unit_key` from npmatch's
   function. *Check:* a parity test against `np_addr_key()`; PO boxes excluded.
   **Built** (`md_place_key()`, `md_unit_id()`, and their SQL macros). Each
   calls npmatch's own function when installed and a port otherwise.
   *Checked:* the R port and the SQL macros are identical to the branch's
   `.np_addr_key()` and `.np_unit_id()`, loaded straight from
   `origin/fix/address-class`, on 4,000 random rows with every PO-box
   spelling. A package test repeats the comparison automatically once that
   npmatch is installed.
3. **`place`, `place_layer`, `place_unit`** with the count, name and suite
   columns, and `place_class` by npmatch's rule. *Check:* on a full database,
   reproduce npmatch's BMF figures over the BMF-only population: 138,629
   shared addresses, 1,188 federated / 1,319 shared / 1,910 building.
   **Built** (`md_build_places()`), with npmatch's thresholds as arguments.
   *Tested* on a fixture with one place of each kind; each gets its class, and
   a crowded address whose suites are barely recorded is `shared`, not
   `building`. *Pending:* npmatch's BMF figures on the full database. They
   will differ by design, since matchdb counts EINs over every layer's own
   current addresses, not BMF rows; `place_layer` can select the BMF layers to
   compare.
4. **Group, care-of and PMB evidence**, and the flags. *Check:* the five
   most-occupied addresses (§1) get the labels a reader would give them, and
   `group_confirmed` agrees with `federated` on most federated places;
   disagreements are listed for review.
   **Built**: `flag_cmra`, `flag_care_of`, `flag_bank_trust`,
   `flag_group_confirmed`, `flag_military_or_gd`, and `place_flags`. Care-of
   agents reuse `care_of_network`'s word list. *Tested on fixtures. Pending:*
   the five addresses on real data, and the agreement between
   `group_confirmed` and `federated`.
5. **Occupancy history and churn** from the ledger. *Check:* known agents (501
   SILVERSIDE RD) churn; known national offices (1 WATERFOWL WAY) do not.
   **Built**, from every own address in `address`, current and historical:
   `n_eins_ever`, `first_year`, `last_year`, `churn`, and `flag_agent_churn`.
   After the rollups are installed, that history is the ledger's. *Tested on
   fixtures. Pending:* the two real addresses.
6. **Building ids** from rooftop geocodes. *Check:* the radius is chosen from
   the distance distribution between geocodes of one `place_key`, not guessed.
   **Built** as a grid: `PointAddress` coordinates rounded to
   `building_digits` (default 4, about 11 m), each place taking its commonest
   cell. *Tested:* two spellings of 127 Filmore Lane share a building.
   *Pending:* measure the radius, and replace the grid with distance
   clustering if cell edges split buildings measurably.
7. **Publish** `addr_freq.parquet` per bundle and the place sidecar; restrict
   `co_tenant` by class. *Check:* `np_addr_freq()` over a bundle's reference
   equals the shipped `addr_freq` exactly; the Phase 1 gate stays at three
   zeros.
   **Built.**
   * Every bundle ships `addr_freq.parquet` over its own rows. It is computed
     by `npmatch::np_addr_freq()` when installed, or by a port identical to the
     branch's function (checked as in step 2).
   * Bundles also ship `place`, `place_layer` and `place_unit` for the places
     they touch.
   * `md_reference()` returns them as `addr_freq` (an `np_addr_freq`) and
     `places`.
   * Co-tenant clusters form only at a plain `cluster` place without the
     care-of, mailbox-store, bank-trust or churn flags.
   *Tested:* the shipped `addr_freq` round-trips identically.
   *Pending:* the Phase 1 gate on a full database.
   `dev/build-matchdb.R` and `dev/build-ledger.R --install` run
   `md_build_places()` after groups and before keys and clusters.

---

## 8. Asks of npmatch

1. **Merge `fix/address-class`** (and `fix/normalizer-special-letters`).
   matchdb adds `street_unit_id` and reruns `md_normalizer_diff()` across the
   signature change.
2. **Export `np_addr_key()` and the class rule** (`np_addr_class()` with its
   thresholds), so matchdb calls them rather than copying them. Failing that,
   expose the thresholds through something like `np_name_rules()`, so a
   matchdb test can check parity.
3. **`np_addr_freq_from_table()`**, to read a shipped table and refuse a
   signature mismatch.
4. **Say which flags npmatch will act on**, for example no PMB suite credit at a
   `cmra`. matchdb ships the flags either way; the routing is npmatch's.

---

## 9. Decisions for later

* **The occupant population** (§4). Recommended: own current addresses only,
  counted per layer.
* **Flag thresholds** (§5b). Measure on the full database before fixing them.
* **The building radius** (§5c). Measure; do not guess.
* **Whether matchdb ever overrides `place_class`.** Recommended: no. The class
  stays npmatch's rule over the tier's rows; matchdb's evidence travels as
  flags, so the two sides never disagree about a label.
