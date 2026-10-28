# Build the per-cell corpus statistics

Corpus statistics depend on which rows a spec selects (`PLAN.md` section
6a), so they cannot be one number per name. They can be one number per
*cell*, where a cell is `layer x variant_class x corroboration band`:
every spec without a cross-cutting filter is a union of cells, and its
statistics are the exact sum of its cells' (section 6c).

## Usage

``` r
md_build_stats(con = NULL)
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

## Value

Row counts of the three tables, invisibly.

## Details

Counted over `name_compact` rows, one per `(ein, name_key)`. Each such
row is in exactly one cell - one layer per EIN, one variant class per
row - so the sums are exact for EIN counts too, not just row counts.

- `stat_cell`:

  `layer, variant_class, band, n_rows`

- `stat_name_cell`:

  `layer, variant_class, band, name_key, n_eins`: EINs holding the name
  in that cell

- `stat_token_cell`:

  `layer, variant_class, band, token, n_rows`: name rows containing the
  token, by
  [`npnormalize::np_token_idf()`](https://nonprofit-open-data-collective.github.io/npnormalize/reference/np_token_idf.html)'s
  rules - split on space, unique per name, at least two characters, no
  stopwords

## Name rows, not frame rows

npmatch's own
[`npnormalize::np_name_freq()`](https://nonprofit-open-data-collective.github.io/npnormalize/reference/np_name_freq.html)
and
[`npnormalize::np_token_idf()`](https://nonprofit-open-data-collective.github.io/npnormalize/reference/np_token_idf.html)
count rows of the compiled frame, where a name is repeated once per
paired address. These cells count names, so an EIN with three addresses
counts once. The difference is real and
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
reports both.
