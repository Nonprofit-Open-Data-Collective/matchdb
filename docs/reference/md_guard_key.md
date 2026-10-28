# Name key used by the guards

npmatch's exact-lookup key,
[`npnormalize::np_name_core()`](https://nonprofit-open-data-collective.github.io/npnormalize/reference/np_name_core.html):
upper case, accents removed, `&` to `AND`, apostrophes and initialism
periods deleted (`ST MARY'S` = `SAINT MARYS`), other punctuation to
spaces, abbreviations expanded, then connector words and legal forms
dropped.

## Usage

``` r
md_guard_key(x)
```

## Arguments

- x:

  Names.

## Value

Character keys, `""` for `NA`.
