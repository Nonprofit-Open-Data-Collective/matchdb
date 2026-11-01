<div id="main" class="col-md-9" role="main">

# matchdb

<div class="section level1">

A disambiguation database for nonprofit record linkage: every name and
address the IRS and 990 filers have recorded for each EIN, with its
source, normalized once and compiled on demand into the reference frame
that
[npmatch](https://github.com/Nonprofit-Open-Data-Collective/npmatch)
matches against.

It is **not** a matching engine. Blocking, comparison, vetoes, scoring
and tiering live in npmatch.

<div class="section level2">

## Install

<div id="cb1" class="sourceCode">

``` r
remotes::install_github("Nonprofit-Open-Data-Collective/matchdb@v0.1.1")  # the current release
remotes::install_github("Nonprofit-Open-Data-Collective/matchdb")         # development version
```

</div>

The current release is **0.1.1**, git tag `v0.1.1`. It pairs with
npmatch 0.1.1 and normalizer signature `v1-3e7b9f9d59bbb19e`. Pin it, in
renv or with `@v0.1.1`, for anything that should reproduce results from
before the normalizer moved into npnormalize.

**The published data moved on 2026-11-01.** The database, bundles and
tranches online are now built with npnormalize 0.1.3, signature
`v1-592912060053c4c3`. Only the development version reads them; 0.1.1
refuses them, as the signature check intends. See
[NEWS.md](https://nonprofit-open-data-collective.github.io/matchdb/NEWS.md).

The development version takes the normalizer from
[npnormalize](https://github.com/Nonprofit-Open-Data-Collective/npnormalize)
and only suggests npmatch. Three packages are involved, and both sides
of a match have to use the same normalizer:

| package     | role                                                                                          | install for the published data                                         |
|-------------|-----------------------------------------------------------------------------------------------|------------------------------------------------------------------------|
| npnormalize | turns names and addresses into keys; its signature is stamped on everything matchdb publishes | **0.1.3**, the commit below                                            |
| matchdb     | the database and the references                                                               | the development version                                                |
| npmatch     | matches your records against a reference                                                      | the development version; 0.1.1 still carries its own, older normalizer |

<div id="cb2" class="sourceCode">

``` r
remotes::install_github("Nonprofit-Open-Data-Collective/npnormalize@6d9c669")  # 0.1.3
remotes::install_github("Nonprofit-Open-Data-Collective/npmatch", upgrade = "never")
remotes::install_github("Nonprofit-Open-Data-Collective/matchdb", upgrade = "never")
```

</div>

`upgrade = "never"` keeps npnormalize at 0.1.3. **npnormalize 0.1.4
moves the signature again**, to `v1-1179714ce1e9d31f`, and the data
published on 2026-11-01 is refused under it until it is rebuilt. Check
what you have with `npnormalize::np_normalize_signature()`.

</div>

<div class="section level2">

## Quick start: download a reference and match

[Getting
started](https://nonprofit-open-data-collective.github.io/matchdb/articles/matchdb.html)
walks through a full example: matching four grant recipients, reading
the results, and looking at the cases that are not clear-cut.

Four references are published, built from the database. Downloading one
needs no AWS account.

| label              | EINs              | names                                    |  rows |
|--------------------|-------------------|------------------------------------------|------:|
| `active-legal`     | current BMF       | legal, DBA                               | 2.74M |
| `active-observed`  | current BMF       | legal, DBA, aliases written by 2+ filers | 2.88M |
| `unified-legal`    | every BMF release | legal, DBA                               | 4.98M |
| `unified-observed` | every BMF release | legal, DBA, aliases written by 2+ filers | 5.13M |

<div id="cb3" class="sourceCode">

``` r
library(matchdb)
b <- md_reference("active-observed", fetch = "missing")   # ~290 MB, once

m <- npmatch::np_cascade(my_query, b$reference,
                         name_freq = b$name_freq, token_idf = b$token_idf,
                         ref_index = b$ref_index)
```

</div>

Each bundle is checked against the md5s it was published with and
against the installed normalizer (npnormalize’s signature). A stale or
altered bundle is refused.

A bundle also carries `b$addr_freq` (how crowded each address is),
`b$places` and `b$clusters` (the families its organizations belong to),
which npmatch’s `np_pair_links()` and `np_cluster_rollup()` read.

</div>

<div class="section level2">

## Look up an organization

With the database downloaded (`md_fetch_db()`, 11.8 GB):

<div id="cb4" class="sourceCode">

``` r
md_lookup("53-0196605")    # entity, names, addresses, events, relations, clusters, ...
md_cluster("53-0196605")   # its families: group ruling, Schedule R system, shared site, ...
```

</div>

</div>

<div class="section level2">

## Compile your own slice

A reference is described by a spec with these settings:

-   **layers**: which EINs.
-   **name and address classes**: which strings.
-   **sources**: who reported them.
-   **corroboration**: how many filers must agree on an alias.

<div id="cb5" class="sourceCode">

``` r
s <- md_spec(layers = c("bmf_active", "bmf_inactive"),
             names = c("legal", "dba", "observed"),
             addresses = c("mailing", "observed"),
             min_corroborators = 2)
r <- md_compile(s)         # r$reference, r$name_freq, r$token_idf, r$report
```

</div>

You don’t need the whole database for this. The database is also
published as parquet files split by layer and class, and
`md_fetch_tranches()` downloads only the files a spec needs:

<div id="cb6" class="sourceCode">

``` r
md_fetch_tranches(s)       # only these layers and classes, once
con <- md_tranche_db()     # a connection md_compile(), md_publish() and md_lookup() take
r <- md_compile(s, con)
md_db_close(con)
```

</div>

`md_tranches(s)` shows what a spec will download before you fetch it.
Every fetch, compile and publish is logged in your matchdb folder:
`md_log()` lists them, and `md_status()` says what is there now.
`md_tranche_diff()` shows what a new release changes. See
`vignette("workspace")`.

The articles explain each choice:

| article                                                                                               | question                                                    |
|-------------------------------------------------------------------------------------------------------|-------------------------------------------------------------|
| [Layers](https://nonprofit-open-data-collective.github.io/matchdb/articles/layers.html)               | which organizations a reference can match                   |
| [Sources](https://nonprofit-open-data-collective.github.io/matchdb/articles/sources.html)             | where each name and address comes from                      |
| [Corroborators](https://nonprofit-open-data-collective.github.io/matchdb/articles/corroborators.html) | how much to trust a name someone else wrote                 |
| [Families](https://nonprofit-open-data-collective.github.io/matchdb/articles/clusters.html)           | which EINs belong together when no single one can be chosen |

Two more explain how the database works: [how corroboration is counted
and
recorded](https://nonprofit-open-data-collective.github.io/matchdb/articles/corroboration-ledger.html),
and [how the database is
updated](https://nonprofit-open-data-collective.github.io/matchdb/articles/updates.html).

</div>

<div class="section level2">

## What is in the database

Built from pinned versions of the IRS Business Master File, 990 e-file
headers, Schedules I, R and C, Form 1023-EZ approvals, the 990-N
e-Postcard, the automatic-revocation list, Part VII officer name keys,
and NCCS address history and geocodes. That gives 4.24M EINs, 12.8M name
rows and 22.0M address rows. Relations between EINs and typed clusters
are built on top.

Every name and address is a rollup of an append-only observation ledger
(48.3M observations), which records which release of which source said
it, and, for a third party, which filer. The ledger ships only in the
maintainer copy, `MATCHDB-full.duckdb` (24.2 GB). `dev/build-matchdb.R`
rebuilds the database from scratch in about 70 minutes. `dev/PLAN.md` is
the design, and `dev/PROCESS.md` records the verification gates.

</div>

<div class="section level2">

## Related repositories

| repo                                                                         | role                                                                                                                                     |
|------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| [npnormalize](https://github.com/Nonprofit-Open-Data-Collective/npnormalize) | the normalizer and its signature. matchdb imports it, and so does npmatch, so both sides of a match key names and addresses the same way |
| [npmatch](https://github.com/Nonprofit-Open-Data-Collective/npmatch)         | the record-linkage engine. matchdb only suggests it; it reads matchdb’s references and depends on nothing here                           |
| [pfmatch](https://github.com/Nonprofit-Open-Data-Collective/pfmatch)         | 990-PF grant-recipient matching: the first consumer, and the benchmark                                                                   |
| [ef2](https://github.com/Nonprofit-Open-Data-Collective/ef2)                 | IRS 990 e-file processing                                                                                                                |

</div>

</div>

</div>
