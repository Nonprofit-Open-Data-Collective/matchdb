# Places: how crowded an address is, and what kind of place it is

Builds the place tables `dev/PLACES.md` describes, so the matching side
knows for any address how many organisations report it, in how many
suites, and whether it is a national office, a fiscal sponsor's mail
drop, a multi-tenant building or an organisation with its foundation.
npmatch labels addresses the same way at run time (`np_addr_freq()`,
branch `fix/address-class`); these tables add what it cannot see.

## Usage

``` r
md_build_places(
  con,
  share_min = 10L,
  unit_coverage_min = 0.5,
  top_share_min = 0.5,
  flag_share = 0.5,
  building_digits = 4L
)
```

## Arguments

- con:

  A DuckDB connection with `address`, `address_derived` and `entity`;
  `name`/`name_derived` (or `name_compact`), `entity_group` and the
  geocode columns are used when present.

- share_min, unit_coverage_min, top_share_min:

  npmatch's class thresholds (its defaults): crowded at `share_min`
  occupants; a building needs two suites and `unit_coverage_min` of
  occupants naming one; federated at `top_share_min` of occupants under
  one name.

- flag_share:

  Share at which a flag's evidence counts (PMB suites, care-of agents,
  one group ruling, churn). To be measured on the full database
  (`dev/PLACES.md` section 9).

- building_digits:

  Decimal places rooftop coordinates are rounded to for a building id. 4
  is about 11 m of latitude; to be measured.

## Value

Row counts, invisibly.

## Details

It writes three tables:

- `place`:

  One row per address that two or more EINs report as their own current
  address. A lookup miss means one occupant, which is about 88% of
  addresses.

- `place_layer`:

  `(place_key, layer, n_eins)`. Layers partition EINs, so the count for
  any selection of layers - active only, unified - is an exact sum, as
  with `ein_key_layer`.

- `place_unit`:

  One row per suite that two or more EINs at a place share.

## Who counts as an occupant

An EIN occupies a place when the place is its **own current address**:
an `address` row of class `mailing` or `principal` (the BMF, the latest
990 header, the e-Postcard). A grantmaker writing a grantee's address
(class `observed`) is not occupancy, and an old address (`historical`)
counts only toward the history columns.

## Keys

`place_key` is npmatch's address key - `street_key`, a space, `zip5`,
empty for a PO box - and `unit_id` its suite identifier ("STE D-2" -\>
`D2`), so a lookup from npmatch never misses on spelling. See
[`md_place_key()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_place_key.md).

## Columns of `place`

- `n_eins`:

  occupants

- `n_name_keys`, `top_name_share`:

  distinct legal name keys among the occupants, and the share holding
  the commonest one: one name dominating is a national office, names
  spread is a sponsor or agent

- `n_units`, `max_eins_per_unit`, `n_eins_with_unit`, `unit_coverage`:

  recorded suites. Coverage travels with the count: at 1,601 crowded BMF
  addresses no record names a suite, and "several suites" can describe
  the data as easily as the building

- `n_pmb_units`, `pmb_share`:

  private-mailbox suites, and the share of occupants with a suite whose
  suite is a PMB

- `n_group_exemptions`, `share_in_largest_group`, `has_group_central`:

  the IRS group rulings among the occupants: a national office its
  chapters file from, confirmed without reading names

- `n_care_of_agents`, `care_of_agent_share`, `bank_trust_share`:

  occupants whose in-care-of name is an agent (bank, trust company, CPA,
  law firm), by the word list `care_of_network` uses

- `n_eins_ever`, `first_year`, `last_year`, `churn`:

  every EIN that has had the place as its own address, current or
  historical, and the share no longer there

- `building_id`, `n_place_keys_in_building`:

  rooftop geocodes rounded to `building_digits` decimals: one building
  written two ways

- `place_class`:

  npmatch's four labels by npmatch's rule and thresholds: `federated`,
  `building`, `shared`, `cluster`

- `flag_*`, `place_flags`:

  what only matchdb sees: `cmra`, `care_of`, `bank_trust`,
  `group_confirmed`, `agent_churn`, `military_or_gd`

- `class_rule`, `normalize_signature`:

  the stamps
