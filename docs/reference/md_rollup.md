<div id="main" class="col-md-9" role="main">

# Build name and address from the ledger

<div class="ref-description section level2">

Phase 5 step 6 (`dev/IDENTITY.md` §6). The ledger holds every
observation; compile, the statistics, the guards, groups and clusters
read `name` and `address`. These functions rebuild those two tables from
the ledger, in the shape and grain today's ingests write, so everything
downstream keeps working:

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_build_rollups(con)

md_compare_rollups(con)

md_install_rollups(con, keep_legacy = TRUE)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A DuckDB connection.

-   keep_legacy:

    Keep the replaced tables as `name_legacy` and `address_legacy`
    (replacing any earlier legacy copy).

</div>

<div class="section level2">

## Value

`md_build_rollups()`: row counts, invisibly.

`md_compare_rollups()`: a data frame per table, source and class: live
rows, rollup rows, and the share of each matched in the other on (EIN,
source, light key).

`md_install_rollups()`: `con`, invisibly.

</div>

<div class="section level2">

## Details

-   `md_build_rollups()`:

    Builds `rollup_name` and `rollup_address` beside the live tables.

-   `md_compare_rollups()`:

    Row counts per source and class, live against rollup, and how many
    rows of each find a match in the other.

-   `md_install_rollups()`:

    Swaps the rollups in, keeping the old tables as `name_legacy` and
    `address_legacy`, and rebuilds `name_derived` and `address_derived`
    from the text-keyed columns (`md_link_derived()`).

</div>

<div class="section level2">

## Grain and columns

One `name` row per `(ein, source, variant_class, light key)`
(`md_light_key()`) with the most frequent spelling, as today's ingests
group. One `address` row per
`(ein, source, class, paired name, street, city, state, ZIP)` under the
light key. Every spelling stays in the ledger; these tables are the view
compile reads. The columns and source tags are today's (`bmf`,
`efile990`, `schedi`, `schedr`, `f1023ez`, `e_postcard`, `revocations`,
`meta_address`), plus:

-   `name_uid`, `address_uid`:

    Content-hash ids, the same on every rebuild. `name_id` and
    `address_id` stay integers, because compile joins on them; they are
    renumbered on each rebuild, and `name_derived` and `address_derived`
    are rebuilt with them, so nothing can be orphaned.

-   `name_text_id`, `address_text_id`:

    The chosen spelling.

-   `n_periods`, `n_mentions`, `n_spells`, `n_support`:

    The counts of §4. `n_support` is the one that measures support for
    that kind: distinct years for a first-party series, rows for
    mentions (only each filer's latest return for a tax year), spells
    for a snapshot, `NULL` for the seed. `n_obs` is set equal to it, so
    compile's tiebreak reads a defined quantity rather than today's mix.

</div>

<div class="section level2">

## What is derived here rather than at ingest

-   `former`: a 990-header legal name whose last year is before the
    EIN's latest legal name.

-   A 990-header address is `mailing` if it is the EIN's most recent,
    `historical` otherwise.

-   Guard inputs (`n_self_filers`, `filer_ein_lo`, `filer_ein_hi`), from
    `asserted_by`. Run `md_guard_observed()` after installing.

Only EINs present in `entity` are kept, as today's ingests do; the count
held back is reported. `entity` itself is not rebuilt: the ledger holds
names and addresses, not the BMF's other attributes.

</div>

<div class="section level2">

## Not carried

The BMF's own `lat`, `lon`, `county`, `cbsa`, `is_po_box` and
`n_vintages` are not in the ledger. `md_install_rollups()` copies them
from the live `address` row with the same EIN, source and spelling; run
`md_ingest_geocode()` after installing, as the build already does, for
the census geography.

</div>

</div>
