# Add related entities disclosed on 527 Schedule R

Form 8871 Schedule R is the political-organisation analogue of Form 990
Schedule R: a 527 names the organisations it is connected to.
[`?md_irs527_shape`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_irs527_shape.md)
profiles the file; this loads it.

## Usage

``` r
md_ingest_irs527_related(con = NULL, path = NULL, version = "v2024-11-15")
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- path:

  Path to `2024-11-POL-ORGS-SCHED-R.csv`.

- version:

  Pinned `irs527_related` version.

## Value

Row counts, invisibly.

## Every row lands with `ein_b` NULL, and that is the source's shape

The file gives `(527 EIN) -> (ENTITY_NAME, address)`. There is no
counterparty EIN anywhere in it. Resolving a name to an EIN is a
*matching* problem and belongs to `npmatch`, so these rows record the
counterparty by name and leave `ein_b` open. `PLAN.md` §4 made `ein_b`
nullable for exactly this source.

The gap is not small and pretending otherwise would mislead a consumer:
of 10,597 distinct counterparty names, **1,564 (14.8%) exactly match a
BMF legal name**. The rest are sponsoring corporations, unions and trade
associations that are largely outside the exempt universe altogether. A
consumer treating `related_name` as resolvable should expect roughly one
in seven to resolve.

## The whole tail maps to `related_entity`, deliberately

`ENTITY_RELATIONSHIP` is free text with 528 distinct values. `Connected`
(54,660) and `Affiliated` (5,801) are 97.4% of rows; the tail runs
`Sponsor` (103), `Partner` (73), `Connected Organization` (56), and on
down to single-occurrence strings.

Every one of them maps to `relation = 'related_entity'` (§4a). A
"connected organisation" is the body that established, administers or
funds the political organisation - a support and control tie, not loose
coordination. That places it with Schedule R rather than in the
`coalition` band, even though the counterparty is usually a corporation
or union rather than a nonprofit.

The alternative - reading sub-types out of the free text - would
manufacture a taxonomy the filers were never asked to use, and
`Common candidate-CA 33rd Assembly Dist.` is not a relation type.
`relation_raw` keeps the original string, so a later mapping can be
derived without re-ingesting. That is the §4 contract for `relation_raw`
and this is the source it was written for.

Note what this source is *not*: two organisations that both appear as
connected to the same political organisation are a `coalition`, and that
is a derived co-membership over a shared counterparty, never a stored
edge. §4a.

`None` (42 rows) is kept rather than dropped: the filer still named an
entity on Schedule R and merely declined to characterise the tie. The
disclosure is the fact; the label is commentary.

## What is dropped

171 rows name the filer itself as its own related entity. Those are
self-loops and carry no information, so they are removed and counted.

Rows are then deduplicated to one per
`(ein_a, related_name, relation_raw)` with `n_obs` recording how many
filings asserted it - each amendment is a fresh row in the source, so
the raw count overstates distinct relations.

## What must not happen

The counterparty name must never become a `name` variant on the 527's
EIN. §10 is explicit that affiliates are not DBAs, and this source most
invites the error: "ASSOCIATION OF SAFETY GROUPS" is a different body
from "ASGM PAC", and aliasing them manufactures precisely the false
match the database exists to prevent. This function writes to
`ein_relation` and nothing else.
