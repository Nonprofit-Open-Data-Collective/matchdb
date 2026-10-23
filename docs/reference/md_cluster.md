# The families an EIN belongs to, and who else is in them

matchdb groups EINs into typed clusters, an EIN may sit in several:
`group_exemption` (an IRS group ruling), `related_system` (Schedule R),
`care_of_network` (a shared in-care-of organisation), `shared_website`,
`brand` (a dominant shared name, such as a federation's chapters) and
`co_tenant` (a shared street address). `md_cluster()` lists an EIN's
clusters and their members, each with its best legal name, layer and
state.

## Usage

``` r
md_cluster(
  ein = NULL,
  cluster_id = NULL,
  types = NULL,
  max_members = 100L,
  con = NULL
)
```

## Arguments

- ein:

  An EIN whose clusters to show. Give this or `cluster_id`.

- cluster_id:

  One or more cluster ids.

- types:

  Cluster types to keep; `NULL` for all.

- max_members:

  The most members listed per cluster. A brand cluster can hold 25,000;
  `size` always reports the full count.

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md);
  opened read-only and closed when `NULL`.

## Value

An `md_cluster`: a list with `clusters` (one row per cluster) and
`members` (one row per listed member).

## Examples

``` r
if (FALSE) { # \dontrun{
md_cluster("53-0196605")
md_cluster("53-0196605", types = "related_system")$members
} # }
```
