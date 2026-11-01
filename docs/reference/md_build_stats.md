<div id="main" class="col-md-9" role="main">

# Build the per-cell corpus statistics

<div class="ref-description section level2">

Corpus statistics depend on which rows a spec selects (`PLAN.md` section
6a), so they cannot be one number per name. They can be one number per
*cell*, where a cell is `layer x variant_class x corroboration band`:
every spec without a cross-cutting filter is a union of cells, and its
statistics are the exact sum of its cells' (section 6c).

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_build_stats(con = NULL)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A connection from `md_db()`.

</div>

<div class="section level2">

## Value

Row counts of the three tables, invisibly.

</div>

<div class="section level2">

## Details

Counted over `name_compact` rows, one per `(ein, name_key)`. Each such
row is in exactly one cell - one layer per EIN, one variant class per
row - so the sums are exact for EIN counts too, not just row counts.

-   `stat_cell`:

    `layer, variant_class, band, n_rows`

-   `stat_name_cell`:

    `layer, variant_class, band, name_key, n_eins`: EINs holding the
    name in that cell

-   `stat_token_cell`:

    `layer, variant_class, band, token, n_rows`: name rows containing
    the token, by `npnormalize::np_token_idf()`'s rules - split on
    space, unique per name, at least two characters, no stopwords

</div>

<div class="section level2">

## Name rows, not frame rows

npmatch's own `npnormalize::np_name_freq()` and
`npnormalize::np_token_idf()` count rows of the compiled frame, where a
name is repeated once per paired address. These cells count names, so an
EIN with three addresses counts once. The difference is real and
`md_compile()` reports both.

</div>

</div>
