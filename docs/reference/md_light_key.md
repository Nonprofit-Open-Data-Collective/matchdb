<div id="main" class="col-md-9" role="main">

# The light key ingests group spellings on

<div class="ref-description section level2">

When an ingest collapses a source's rows to one name per EIN, it groups
them on this key and keeps the most frequent raw spelling in each group
(`md_modal_sql()`). The key is deliberately light: it merges spellings
that differ only in how they are typed, and leaves everything else -
misspellings, abbreviations, word order - for the normalizer's derived
columns. So FOUNDATION and FOUNDAITON stay apart here.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_light_key(x)
```

</div>

</div>

<div class="section level2">

## Arguments

-   x:

    A character vector.

</div>

<div class="section level2">

## Value

A character vector of keys; `NA` becomes `""`.

</div>

<div class="section level2">

## Details

The rule is npmatch's own name cleaning (`.np_basic_clean()`), so a key
built here and a key npmatch builds for a query agree. The steps, in
order:

1.  Accent marks are removed: É to E, ñ to n, ö to o.

2.  Letters that are not an accented form of another letter are written
    the way English text writes them: Ø to O, Ł to L, Đ to D, ı to i, Æ
    to AE, Œ to OE, ß and ẞ to SS, Þ to TH (npmatch's
    `.np_special_letters`).

3.  `&` becomes the word AND, so "A & B", "A&B" and "A AND B" are one.

4.  Uppercase.

5.  Joiners are **deleted**: every apostrophe (' ‘ ’ ʼ ´ \`) and any
    period between two letters or digits. "BO'S PLACE" is "BOS PLACE"
    and "F.I.N.D." is "FIND", as the BMF holds them. A period that
    already separates words keeps its break: "ST. LUKES" is "ST LUKES".

6.  Every other character outside A-Z and 0-9 becomes a **space**:
    punctuation, tabs and newlines, and any non-Latin character. So
    "WINSTON-SALEM", "A/B" and "SMITH,JONES" keep two words each.

7.  Runs of spaces become one; leading and trailing spaces go.

History. Until 2026-10-25 (morning) steps 1-3 did not exist and every
non-alphanumeric character was deleted: "CAFÉ" became "CAF", `&`
vanished while AND was kept, and a tab joined two words. The first fix
kept deletion for punctuation, which glued "WINSTON-SALEM" into one word
where npmatch keeps two; steps 5-6 now follow npmatch exactly.

One known residual: npmatch transliterates with ICU's Latin-ASCII, which
also spells out rarer forms (ligatures such as "ﬁ", for example). SQL
has no Latin-ASCII, so here those become a space. They are vanishingly
rare in organisation names.

Ingests compute the key in SQL through the macro `md_light_key(x)`
(installed by `.md_light_key_macro()`); this R function is the same
rule, and a test holds the two to identical output.

</div>

</div>
