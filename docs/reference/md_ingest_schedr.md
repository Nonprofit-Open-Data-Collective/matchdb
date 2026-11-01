<div id="main" class="col-md-9" role="main">

# Ingest Schedule R related organisations as observed names and addresses

<div class="ref-description section level2">

The same files `md_ingest_relations()` reads for its affiliate pairs
also carry the related organisation's **name and address**, written by
the filer. That makes Schedule R Part II a second
`(name, address) -> EIN` source of the same kind as Schedule I, and
reading only the EIN pair discards it.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ingest_schedr(
  version = "v2_2",
  con = NULL,
  min_corroborators = 1L,
  guard = TRUE
)
```

</div>

</div>

<div class="section level2">

## Arguments

-   version:

    Pinned `efile_related` version.

-   con:

    A connection from `md_db()`.

-   min_corroborators:

    Minimum distinct filers. Defaults to 1; see above for how
    corroboration actually distributes here.

-   guard:

    Run `md_guard_observed()` on the loaded rows (see
    `md_ingest_schedi()`). A filer listing itself as a related
    organisation under a different name is the own-EIN case here.

</div>

<div class="section level2">

## Value

Row counts, invisibly.

</div>

<div class="section level2">

## How this differs from Schedule I

Both are third parties writing about an EIN, so both are `observed`
(section 3a). The expectation going in was that Schedule R would be the
weaker of the two on corroboration - a related organisation is disclosed
only by its own affiliates, of which there might be one or two, where a
Schedule I recipient is written about by whoever happened to fund it.

**Measured, that is wrong, and in the useful direction.** Schedule R is
the better corroborated source of the pair:

<div class="sourceCode">

      distinct filers    schedi          schedr
      1                  1,339,769 77.8
      2-4                  276,766 16.1
      5-19                  95,735  5.6
      20+                   10,534  0.6

</div>

Fewer single-filer rows, and eight times the share at twenty or more.
Group structure is why: a national organisation with hundreds of
chapters is disclosed by every one of them, so the very entities most
likely to be confused with their affiliates are the ones carrying the
most corroboration.

The practical consequence is the opposite of what was assumed - a shared
`min_corroborators` floor costs *less* here than on Schedule I, not
more.

</div>

<div class="section level2">

## The near-identical-name hazard

Schedule R names are systematically related to the filer's, since an
organisation and its supporting foundation usually share a stem. That is
exactly the condition section 10 warns produces false matches.

What makes it safe is that every row carries the **disclosed** EIN. The
name attaches to the organisation it names rather than to the filer,
which is the difference between recording an affiliate's name as an
alias of itself - fine, and the point - and as an alias of its parent,
which section 10 forbids.

</div>

</div>
