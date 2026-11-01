<div id="main" class="col-md-9" role="main">

# Name key used by the guards

<div class="ref-description section level2">

npmatch's exact-lookup key, `npnormalize::np_name_core()`: upper case,
accents removed, `&` to `AND`, apostrophes and initialism periods
deleted (`ST MARY'S` = `SAINT MARYS`), other punctuation to spaces,
abbreviations expanded, then connector words and legal forms dropped.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_guard_key(x)
```

</div>

</div>

<div class="section level2">

## Arguments

-   x:

    Names.

</div>

<div class="section level2">

## Value

Character keys, `""` for `NA`.

</div>

</div>
