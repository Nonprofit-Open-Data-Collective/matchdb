# Describe a reference: which EINs, which names, which addresses

A spec is the whole definition of a compiled reference (`PLAN.md`
section 5). It is small, serialisable and hashed: two references with
the same `spec_hash` were selected the same way.
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
turns it into the frame npmatch matches against.

## Usage

``` r
md_spec(
  layers = "bmf_active",
  names = c("legal", "dba"),
  addresses = "mailing",
  sources = NULL,
  min_corroborators = 1L,
  max_names = NULL,
  max_addresses = NULL,
  drop_before_year = NULL,
  dba_as = c("column", "row"),
  label = NULL
)
```

## Arguments

- layers:

  Layers to include; see
  [`md_layers()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_layers.md).

- names:

  Name variant classes to include.

- addresses:

  Address variant classes to include.

- sources:

  Optional: only strings from these sources (`bmf`, `efile990`,
  `f1023ez`, `schedi`, `schedr`, `meta_address`). `NULL` takes every
  source. Since the e-file and 1023-EZ ingests, `legal` and `mailing`
  are no longer BMF-only, so a reference meant to reproduce a BMF frame
  needs `sources = "bmf"`. Names are collapsed across sources, so a
  source filter cuts across the statistics cells, and those statistics
  are computed directly.

- min_corroborators:

  Minimum distinct filers behind an `observed` name: 1, 2, 5 or 20.

- max_names:

  Optional cap per class, as a named integer vector, e.g.
  `c(observed = 3)`. Classes not named are uncapped. Capping per class,
  not overall, keeps a legal name from being displaced by aliases
  (section 7c).

- max_addresses:

  Optional cap on first-party addresses per EIN.

- drop_before_year:

  Optional: drop names and addresses last seen before this year. Rows
  with no year (most BMF rows) are kept.

- dba_as:

  `"column"` puts each EIN's best DBA in the `dba` field of its
  legal-name rows, the shape npmatch's BMF reference has; further DBAs
  become rows. `"row"` makes every DBA its own row.

- label:

  Optional name for the spec, e.g. `"active-observed"`. Not part of the
  hash.

## Value

An object of class `md_spec`.

## The two selection axes

`layers` chooses **which EINs** can be matched (`PLAN.md` section 3).
Every EIN has exactly one layer, so a union of layers is a clean union
of EINs. `names` and `addresses` choose **which strings** those EINs
carry, by variant class. An EIN in an active-BMF layer also has names
from its own filings and from Schedule I; `names` decides which of those
count.

`in_care_of` is not a selectable name class: it names someone other than
the organisation (a person, an agent or a parent). Its organisational
content is in the `care_of_network` clusters
([`md_build_clusters()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_build_clusters.md)).

## Filters that keep statistics exact

Corpus statistics for a spec are sums over precomputed cells (layer x
variant class x corroboration band;
[`md_build_stats()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_build_stats.md)).
A filter that cuts across cells would break that, so
`min_corroborators` - which applies to `observed` names only - must be a
band edge: 1, 2, 5 or 20. `max_names` and `drop_before_year` do cut
across cells; a spec using them is still compiled exactly, but its
statistics are computed directly from the selected rows rather than
summed from cells, and the report says so.
