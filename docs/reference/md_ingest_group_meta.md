# Add historical group membership from the NCCS group metadata

`metadata-group-number` records, per EIN, the group exemption number
observed across vintages as a `;;`-delimited history, plus `.last` and
`.best` resolutions of it.

## Usage

``` r
md_ingest_group_meta(con = NULL, path = NULL, version = "2023-09")
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- path:

  Path to `metadata-group-number.csv`.

- version:

  Pinned `meta_group_number` version.

## Value

Row counts, invisibly.

## This is a small source, and saying so is part of the job

Measured against the database before loading it:

                           meta file     BMF
      EINs with a GEN         33,274   647,569
      distinct GENs            2,958     4,917

Of the 33,274, 27,065 agree with the BMF, 5,180 carry a GEN the BMF does
not, and 1,219 disagree. The net contribution is **2,913 new
parent-to-member pairs against 320,117 already present** - under 1%.

It is loaded anyway because those 5,180 are not noise: an EIN whose
history records a group the current BMF does not is one that *left* a
group, and former membership is exactly what explains a lingering name
similarity to a national parent. That is worth having in a
disambiguation database even at this volume. What would not be worth
having is pretending it is bigger.

## Conflicts resolve to the BMF, on vintage rather than preference

The 1,219 disagreements are settled by taking the BMF's value, because
this file is a **2023-09** extract and the pinned BMF is **2026-07**.
That is a statement about which snapshot is more recent, not a judgement
that NCCS is less reliable than the IRS. If a newer group extract
arrives the rule should be re-examined rather than inherited.

In practice the rule is enforced by construction: rows are only added
for EINs where the BMF has no GEN at all, so a conflict can never
overwrite anything. The count is reported so the disagreement is visible
rather than absorbed.

## Why the other two files are not loaded

`metadata-group-aff` and `metadata-group-return` are the same 835,340
EINs with `group.aff.incl` and `group.return` flags, and both are
**95.4% null**. What they describe is *filing behaviour* - whether an
organisation is included in a group return - rather than structure. That
is a property of a filing, not a relation between two EINs, so it has no
home in `ein_relation` and no bearing on disambiguation. They stay
registered and unloaded.
