<div id="main" class="col-md-9" role="main">

# The families an EIN belongs to, and who else is in them

<div class="ref-description section level2">

matchdb groups EINs into typed clusters, an EIN may sit in several:
`group_exemption` (an IRS group ruling), `related_system` (Schedule R),
`care_of_network` (a shared in-care-of organisation), `shared_website`,
`brand` (a dominant shared name, such as a federation's chapters) and
`co_tenant` (a shared street address). `md_cluster()` lists an EIN's
clusters and their members, each with its best legal name, layer and
state.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_cluster(
  ein = NULL,
  cluster_id = NULL,
  types = NULL,
  max_members = 100L,
  con = NULL
)
```

</div>

</div>

<div class="section level2">

## Arguments

-   ein:

    An EIN whose clusters to show. Give this or `cluster_id`.

-   cluster_id:

    One or more cluster ids.

-   types:

    Cluster types to keep; `NULL` for all.

-   max_members:

    The most members listed per cluster. A brand cluster can hold
    25,000; `size` always reports the full count.

-   con:

    A connection from `md_db()`; opened read-only and closed when
    `NULL`.

</div>

<div class="section level2">

## Value

An `md_cluster`: a list with `clusters` (one row per cluster) and
`members` (one row per listed member).

</div>

<div class="section level2">

## Examples

<div class="sourceCode">

``` r
if (FALSE) { # \dontrun{
md_cluster("53-0196605")
md_cluster("53-0196605", types = "related_system")$members
} # }
```

</div>

</div>

</div>
