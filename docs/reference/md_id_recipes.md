<div id="main" class="col-md-9" role="main">

# The id recipes

<div class="ref-description section level2">

One row per recipe tag: what it identifies and the fields that go into
it, in order. Append-only, like `md_layers()`: a recipe is never edited,
only superseded by a new tag, because an edit would silently change what
every stored id of that tag refers to.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_id_recipes()
```

</div>

</div>

<div class="section level2">

## Value

A data frame with `tag`, `identifies`, `fields`.

</div>

<div class="section level2">

## Details

Observation ids come in two shapes
([md_ledger](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ledger.md)):
a spell id for snapshot sources, and a row id for every other kind. The
row id hashes the row's content, so a corrected value in a re-released
filing is a new observation rather than an update a diff cannot see.

</div>

</div>
