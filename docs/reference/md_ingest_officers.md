# Ingest officer, director and key-employee name keys from Form 990 Part VII

Writes `person_key`: one row per `(ein, person_key)` with the years the
person is listed.
[`md_build_ein_key()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_build_ein_key.md)
turns it into the `person` kind of `ein_key`, so a hard case can find
candidates through a shared board member.

## Usage

``` r
md_ingest_officers(version, con = NULL)
```

## Arguments

- version:

  Pinned `efile_officers` version, e.g. `"v3_1"`.

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

## Value

Rows written, invisibly.

## A key, not a directory

Part VII lists people by name, with title, hours and compensation. Only
the name is read, and only as a matching key: uppercased, punctuation
and single letters removed, titles and suffixes dropped (`DR`, `REV`,
`JR`, `MD`, `CPA`, ...), the remaining words sorted - so `SMITH, JOHN A`
and `JOHN SMITH` are one key. Titles, hours and compensation are not
stored, and rows naming an organisation as trustee (a bank, a law firm)
are skipped: those are agents, not people.

## Most keys are weak, and n_eins_sharing says which

A common name on hundreds of boards confirms nothing; an uncommon one
shared by two EINs is a strong link. The key is useful only with its
sharing count, which `ein_key` carries.
