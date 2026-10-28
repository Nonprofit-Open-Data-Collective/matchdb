# matchdb

A disambiguation database for nonprofit record linkage: every name and address
the IRS and 990 filers have recorded for each EIN, with its source, normalized
once and compiled on demand into the reference frame that
[npmatch](https://github.com/Nonprofit-Open-Data-Collective/npmatch) matches
against.

It is **not** a matching engine. Blocking, comparison, vetoes, scoring and
tiering live in npmatch.

## Install

```r
remotes::install_github("Nonprofit-Open-Data-Collective/matchdb@v0.1.1")  # the current release
remotes::install_github("Nonprofit-Open-Data-Collective/matchdb")         # development version
```

The current release is **0.1.1**, git tag `v0.1.1`. It pairs with npmatch 0.1.1
and normalizer signature `v1-3e7b9f9d59bbb19e`, which the published database,
bundles and tranches were built with. See [NEWS.md](NEWS.md). Pin it, in renv
or with `@v0.1.1`, for anything that should reproduce results from before the
normalizer moves into npnormalize.

The development version takes the normalizer from
[npnormalize](https://github.com/Nonprofit-Open-Data-Collective/npnormalize)
and only suggests npmatch. Install npmatch too to match against a reference:

```r
remotes::install_github("Nonprofit-Open-Data-Collective/npmatch")
```

## Quick start: download a reference and match

[Getting started](https://nonprofit-open-data-collective.github.io/matchdb/articles/matchdb.html) walks through a full example: matching four grant recipients, reading the results, and looking at the cases that are not clear-cut.

Four references are published, built from the database. Downloading one needs
no AWS account.

| label | EINs | names | rows |
|---|---|---|---:|
| `active-legal` | current BMF | legal, DBA | 2.75M |
| `active-observed` | current BMF | legal, DBA, aliases written by 2+ filers | 2.89M |
| `unified-legal` | every BMF release | legal, DBA | 4.98M |
| `unified-observed` | every BMF release | legal, DBA, aliases written by 2+ filers | 5.14M |

```r
library(matchdb)
b <- md_reference("active-observed", fetch = "missing")   # ~260 MB, once

m <- npmatch::np_cascade(my_query, b$reference,
                         name_freq = b$name_freq, token_idf = b$token_idf,
                         ref_index = b$ref_index)
```

Each bundle is checked against the md5s it was published with and against the
installed normalizer (npnormalize's signature). A stale or altered bundle is
refused.

## Look up an organization

With the database downloaded (`md_fetch_db()`, about 10 GB):

```r
md_lookup("53-0196605")    # entity, names, addresses, events, relations, clusters, ...
md_cluster("53-0196605")   # its families: group ruling, Schedule R system, shared site, ...
```

## Compile your own slice

A reference is described by a spec with these settings:

- **layers**: which EINs.
- **name and address classes**: which strings.
- **sources**: who reported them.
- **corroboration**: how many filers must agree on an alias.

```r
s <- md_spec(layers = c("bmf_active", "bmf_inactive"),
             names = c("legal", "dba", "observed"),
             addresses = c("mailing", "observed"),
             min_corroborators = 2)
r <- md_compile(s)         # r$reference, r$name_freq, r$token_idf, r$report
```

You don't need the whole database for this. The database is also published as
parquet files split by layer and class, and `md_fetch_tranches()` downloads
only the files a spec needs:

```r
md_fetch_tranches(s)       # only these layers and classes, once
con <- md_tranche_db()     # a connection md_compile(), md_publish() and md_lookup() take
r <- md_compile(s, con)
md_db_close(con)
```

`md_tranches(s)` shows what a spec will download before you fetch it. Every
fetch, compile and publish is logged in your matchdb folder: `md_log()` lists
them, and `md_status()` says what is there now. `md_tranche_diff()` shows
what a new release changes. See `vignette("workspace")`.

The articles explain each choice:
[layers](https://nonprofit-open-data-collective.github.io/matchdb/articles/layers.html),
[sources](https://nonprofit-open-data-collective.github.io/matchdb/articles/sources.html),
[corroborators](https://nonprofit-open-data-collective.github.io/matchdb/articles/corroborators.html).

## What is in the database

Built from pinned versions of the IRS Business Master File, 990 e-file headers,
Schedules I, R and C, Form 1023-EZ approvals, the 990-N e-Postcard, the
automatic-revocation list, Part VII officer name keys, and NCCS address
history and geocodes. That gives 4.24M EINs, 12.8M name rows and 22.0M
address rows. Relations between EINs and typed clusters are built on top.

`dev/build-matchdb.R` rebuilds it from scratch in about 70 minutes.
`dev/PLAN.md` is the design, and `dev/PROCESS.md` records the verification
gates.

## Related repositories

| repo | role |
|---|---|
| [npmatch](https://github.com/Nonprofit-Open-Data-Collective/npmatch) | the record-linkage engine. matchdb imports it; it depends on nothing here. |
| [pfmatch](https://github.com/Nonprofit-Open-Data-Collective/pfmatch) | 990-PF grant-recipient matching: the first consumer, and the benchmark |
| [ef2](https://github.com/Nonprofit-Open-Data-Collective/ef2) | IRS 990 e-file processing |
