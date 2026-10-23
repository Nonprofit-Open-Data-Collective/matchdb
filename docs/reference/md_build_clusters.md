# Build the cluster layer: typed, many-to-many families of EINs

Writes `cluster` (one row per cluster), `cluster_member` (one row per
cluster and EIN) and `cluster_footprint` (members per cluster, layer and
state). An EIN can belong to many clusters, of different types. A
chapter that is hard to match on its own can then be matched one level
up: a query whose name matches one member and whose address matches
another is still a strong match to the cluster.

## Usage

``` r
md_build_clusters(
  con = NULL,
  types = c("group_exemption", "related_system", "care_of_network", "shared_website",
    "brand", "co_tenant"),
  max_cotenants = 3L,
  max_website = 5000L,
  brand_min_share = 0.5,
  brand_min_eins = 10L,
  brand_alone_share = 0.8
)
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- types:

  Which cluster types to build.

- max_cotenants:

  Largest shared place that still counts as co-tenancy.

- max_website:

  Largest website key that still forms a cluster.

- brand_min_share, brand_min_eins:

  The brand-word thresholds above.

- brand_alone_share:

  An anchor this concentrated needs no second word of the brand name to
  make an EIN a member.

## Value

Clusters and memberships per type, invisibly.

## Cluster types

- `group_exemption` (`GRP-`):

  the components of `entity_group` - see
  [`md_build_groups()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_build_groups.md).
  Central is `group_central_ein`.

- `related_system` (`SYS-`):

  one cluster per Schedule R discloser: the filer and every related or
  disregarded entity it lists that is in `entity`. A star, never a
  connected component: chained together these edges form one component
  of 117,869 EINs across the health and university sectors. Overlapping
  stars are kept as they are.

- `care_of_network` (`ICO-`):

  one cluster per organisation named in other EINs' in-care-of field.
  Only values that read as an organisation are used: not a person
  (census first name and surname), not a role (`TREASURER`), not an
  agent (bank, trust company, CPA, law firm); naming exactly one EIN's
  legal or dba name, of two or more words, in the same state. Needs the
  `peopleparser` census name table.

- `shared_website` (`WEB-`):

  one cluster per website key held by two or more EINs (at most
  `max_website`). A national body's site written by its chapters.

- `brand` (`BRD-`):

  one cluster per brand word: a name word that is concentrated in one
  name, the way `TOASTMASTERS` is, rather than spread across many, the
  way `BAPTIST` is. A word is a brand when one full name holds at least
  `brand_min_share` of the EINs carrying the word, and that name is held
  by at least `brand_min_eins` EINs. Each dominant name gives one brand,
  anchored on its most concentrated word: `LIONS`, not `CLUBS`;
  `AMATEUR`, not `STATES`. A first pass let every word of a dominant
  name be its own brand, and `STATES` gathered 42,951 EINs. Members are
  every EIN whose legal or dba name contains the anchor word. This is
  what reaches the 63% of Toastmasters clubs that are in no group
  exemption.

- `co_tenant` (`CTN-`):

  one cluster per street address shared by 2 to `max_cotenants` EINs: a
  school and its PTO, a hospital and its foundation. Larger shared
  places are registered agents and processing centres, which say nothing
  about affiliation.

## Columns

`cluster`: `cluster_id`, `cluster_type`, `central_ein` (NULL where the
type has none), `size`, `label` (the central EIN's legal name, or the
shared key) and `brand_tokens` (name words held by at least half the
members, for clusters of three or more).

`cluster_member`: `cluster_id`, `ein`, `role` (`central`, `parent`,
`intermediate` or `member`) and `evidence`.

`cluster_footprint`: `cluster_id`, `layer`, `state`, `n_eins`. Layers
partition EINs, so the footprint of any selection of layers is the exact
sum of its rows - the same rule as `ein_key_layer`.

## What this does not do

It does not nest clusters into levels (chapter, state body, national),
and it does not merge overlapping clusters. Both are left to the
consumer, which can see every membership.
