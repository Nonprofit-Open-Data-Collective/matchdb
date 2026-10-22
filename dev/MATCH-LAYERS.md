# Match layers: identifiers and clusters

**Written 2026-10-22.** Code: `R/md-ein-key.R` (`md_build_ein_key()`),
`R/md-clusters.R` (`md_build_clusters()`). Tests: `tests/testthat/test-match-layers.R`.
Measured on the e-file v3_1 build.

Two layers for the cases a name cannot settle:

* **`ein_key`** finds candidates through something other than the name: a
  shared place or website.
* **`cluster`** lets a match stop one level up, at the family, when no single EIN
  can be chosen. Examples: a chapter of a federation, a hospital system, a
  school and its PTO.

Neither stores query-dependent results. Both are facts about the database, and
the matcher does the rest.

## `ein_key`: one long table of identifiers

| kind | rows | EINs | keys | keys held by one EIN |
|---|---:|---:|---:|---:|
| name | 6,229,475 | 4,028,979 | 4,767,584 | 4,427,996 |
| place | 8,938,347 | 3,424,510 | 7,057,686 | 6,215,078 |
| website | 895,604 | 792,564 | 821,354 | 791,448 |
| email_domain | 5,929 | 5,871 | 4,019 | 3,654 |

`n_eins_sharing` is the rule for use:

* **A key held by one EIN** can propose a candidate on its own.
* **A widely shared key** (`1 WATERFOWL WAY|38120`, 5,422 EINs) can only confirm
  a candidate found another way.

**`ein_key_layer` holds the same count per layer.** Layers partition EINs, so
the count within any selection of layers is the exact sum of its rows. That
keeps "stack the layers you want" exact for these counts, as PLAN.md §6c
requires for corpus statistics.

**People are not in yet.** Officers and key employees (990 Part VII) would be a
fifth kind, `person`. They should be held to the same rule: only names held by
few EINs, and only as confirmation.

## `cluster` and `cluster_member`: typed, many-to-many

| type | clusters | memberships | median | largest | built from |
|---|---:|---:|---:|---:|---|
| `group_exemption` (`GRP-`) | 3,700 | 450,969 | 16 | 17,902 | `entity_group` |
| `related_system` (`SYS-`) | 95,437 | 1,079,440 | 2 | 1,024 | Schedule R, one star per discloser |
| `care_of_network` (`ICO-`) | 2,588 | 8,584 | 2 | 185 | in-care-of values naming one other org |
| `shared_website` (`WEB-`) | 30,226 | 106,426 | 2 | 1,555 | website keys held by 2+ EINs |
| `brand` (`BRD-`) | 518 | 344,962 | 88 | 24,308 | a concentrated name word |
| `co_tenant` (`CTN-`) | 711,067 | 1,559,606 | 2 | 3 | street addresses shared by 2-3 EINs |

These cover 843,536 clusters over 1.57M EINs. An EIN is in up to a dozen
clusters: 942,504 are in one, 356,584 in two, 129,580 in three.

`cluster_footprint` counts members per cluster, layer and state, so a
cluster-level location comparison can be made against any layer selection.

### What each type had to be guarded against

* **`related_system`: a star, never a component.** Chained together, Schedule R
  edges make one component of 117,869 EINs (`RELATION-BUILD-PLAN.md`). Each
  discloser instead gets its own cluster of the entities it lists. Overlapping
  stars are kept as they are.
* **`care_of_network`: most in-care-of values are not organisations.** Of 1.6M
  values, 1.05M are people (census first name and surname), 103K are roles or
  titled people, 32K are agents (banks, trust companies, CPA and law firms) and
  16K are the organisation's own name. A value is used only when it is none of
  these, names exactly one EIN's legal or dba name in two or more words, and is
  in the same state. The state rule is what removes people who share a name
  with an eponymous foundation (`CALVIN JONES` / `CALVIN JONES FOUNDATION`).
  Before it, 6% of candidate links were already related; after, the sample
  reads as genuine (Shriners temples, a charter school under its network, a
  booster club under its association).
* **`brand`: three passes.**
  1. Every concentrated word was a brand. `STATES` (from AMATEUR ATHLETIC UNION
     OF THE UNITED STATES) gathered 42,951 EINs, `CLUBS` 40,685, `PARENT` 23,900.
  2. One brand per dominant name, anchored on its most concentrated word, and a
     50% share threshold. That gave `LIONS`, not `CLUBS`, and `AMATEUR`, not
     `STATES`. But the anchor still took every use of the word: `COLUMBUS`
     gathered Columbus, Ohio.
  3. An anchor with other uses (share under 80%) also needs a second word of
     the brand's name, trailing S ignored. `SPRINGFIELD LIONS CLUB` is in;
     `DETROIT LIONS` and `COLUMBUS SYMPHONY` are not. `BRD-COLUMBUS` is now only
     Knights of Columbus councils. Placeholders held as legal names
     (`NOT APPLICABLE`) are dropped.
* **`co_tenant` stops at three.** Shared places of 4 or more are mostly
  registered agents, processing centres and national headquarters. 852K pairs
  sit at places shared by 2-3 EINs, and only 5.7% of those pairs are already in
  `ein_relation`, so this is the largest new source of family links. It is also
  the least verified.

## What is not done

* **No levels.** Clusters do not nest into chapter, state body and national,
  and overlapping clusters are not merged. The consumer sees every membership.
* **No cluster scoring.** That belongs in npmatch. The proposed first version is
  a roll-up after EIN-level scoring:
  1. When no EIN reaches YES, group the candidates by `cluster_id`.
  2. Accept a cluster when its members together show the brand tokens and a
     location inside `cluster_footprint`.
  3. Record the result as a `CLUSTER`-tier match.

  The naive "sum of each attribute's best score over members" inflates with
  cluster size: a 17,902-member cluster has some member near any query. So it
  needs the cluster-specific comparisons above, not raw maxima.
* **Not validated against ground truth.** Brand and co-tenant clusters in
  particular should be checked against pfmatch's held-out group cases (63
  federated cases, `GROUP-STRUCTURE-FINDINGS.md` §3) before a matcher trusts
  them.
