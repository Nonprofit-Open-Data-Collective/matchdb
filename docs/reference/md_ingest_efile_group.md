# Add group membership from what filers report on Form 990 line H

The 990 header carries three group fields that
[`md_ingest_efile_header()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_efile_header.md)
reads past: H(a) `RETURN_GROUP_X` (is this a group return), H(b)
`ALL_AFFIL_INCL_X` (are all subordinates included) and H(c)
`GROUP_EXEMPT_NUM`. H(c) is the organisation's **own** statement of the
group it belongs to, filed annually, and it is a different witness from
the BMF.

## Usage

``` r
md_ingest_efile_group(con = NULL, dir = NULL, version = "v2_2")
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- dir:

  Directory of `F9-P00-T00-HEADER-*.CSV`.

- version:

  Pinned `efile_header` version; also names `dir` when it is `NULL`.

## Value

Row counts, invisibly.

## What it adds that the BMF cannot

Measured over 2009-2024, 259,368 filings carry a usable GEN across
42,997 EINs and 3,497 groups. Against the pinned BMF:


      (EIN, GEN) pairs in the e-file        43,603
        BMF records no GEN for that EIN      7,015
        BMF agrees                          34,806
        BMF disagrees                        1,782

The 7,015 are the point. They are organisations that told the IRS on
their own return which group they belong to and whose BMF row does not
say so - more than twice what the NCCS historical extract contributed.

The second thing it adds is **time**. The BMF is a snapshot with no
notion of when membership began or ended; a filing is dated. New rows
therefore carry `first_year`/`last_year` from the tax years the claim
was actually filed in, and `n_obs` counts the filings asserting it.

## Disagreements resolve to the BMF, on vintage

The 1,782 conflicts are settled the same way
[`md_ingest_group_meta()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_group_meta.md)
settles its 1,219: the BMF is a 2026-07 snapshot and the e-file runs to
2024, so the newer source wins. As there, the rule is enforced by
construction - rows are only written for EINs the BMF gives no GEN at
all - so a conflict cannot overwrite anything. The count is reported
rather than absorbed.

The 34,806 agreements are deliberately **not** written. They would
duplicate edges
[`md_ingest_relations()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_relations.md)
already emitted, to say the same thing twice. The cost is that those
edges stay untimestamped; timestamping an edge owned by another source
is a cross-source update and does not belong in an append-only ingest.
Left for a compile-time join if a consumer ever needs it.

## Placeholder GENs are not group exemption numbers

`0000` (1,352 filings), `0001` (1,291) and `9999` (315) are what filers
put in the box when they have nothing to put in the box. They are
dropped. So is anything that does not reduce to four digits.

## Finding the parent, and admitting when it cannot be found

Membership is stored parent-to-member (§4: never a clique), so every
group needs a parent. Three sources are tried in order, most
authoritative first:

1.  the BMF's own coded parent - `affiliation_code` 6 or 8, per
    [`md_ingest_relations()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_relations.md).
    Covers 2,504 of the 3,497 groups.

2.  an EIN that filed a **group return** under that GEN. A group return
    is filed by the central organisation, so H(a) plus H(c) is a parent
    claim. Covers 96 more.

3.  `gen_parent`, the derived GEN-to-parent table. Covers 37 more. No
    ingest builds it (it was made by hand in the first database), so it
    is used only when the table exists, and a build from scratch skips
    it.

**860 groups (25%) still have no identifiable parent and produce no
rows.** That is reported, not patched: inventing a parent to make the
join succeed would fabricate the hierarchy the table exists to record.
