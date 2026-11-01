<div id="main" class="col-md-9" role="main">

# The `ein_relation` column list, named once

<div class="ref-description section level2">

Every ingest that writes `ein_relation` used to do it by **positional**
`INSERT ... SELECT`. That works until the table gains a column, at which
point all of them write the new column silently and wrongly - the
failure is a shifted value, not an error. Adding `controlled_512` forced
the fix, and the fix is to name the columns.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
.md_relation_cols(extra = NULL)
```

</div>

</div>

<div class="section level2">

## Arguments

-   extra:

    Columns this particular writer supplies beyond the common set.

</div>

<div class="section level2">

## Value

A comma-separated column list for an `INSERT`.

</div>

<div class="section level2">

## Details

Naming them in each ingest separately would recreate the same drift one
level up, so the list lives here and every writer calls this. A future
column is added in two places - the `CREATE TABLE` in
`md_ingest_relations()` and this vector - and every ingest keeps
working.

</div>

</div>
