# Put a frame in comparison normal form

Removes the differences that carry no information, so the ones that
remain are unambiguously behavioural:

## Usage

``` r
md_normal_form(d, columns, key = c("ein", "name_key", "street_key", "zip5"))
```

## Arguments

- d:

  A data frame.

- columns:

  Character vector of columns to compare. Required — passing the live
  field set is the mistake this argument exists to prevent.

- key:

  Columns identifying a row. Default the reference-frame key.

## Value

`d` in normal form, with a `.occ` column disambiguating rows that share
a key (so duplicates are compared as a multiset rather than collapsed).

## Details

1.  restrict to `columns` — the **pinned** list from the 0a baseline
    manifest, never
    [`npmatch::np_fields`](https://nonprofit-open-data-collective.github.io/npmatch/reference/np_fields.html)
    resolved at run time (Phase 0c adds `variant_class` to it, so a live
    lookup would compare a baseline built without that column against a
    candidate built with it)

2.  coerce every comparison column to character, and `""` to `NA`

3.  order rows by `key`, dropping incidental row order

4.  order columns by name
