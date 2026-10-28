# What tranches are published, what they cost, and what changed

`md_tranches()` lists the files in a tranche build: table, layer, class,
rows, size, and whether each is already here. Given a spec, it marks the
files
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
needs for it and totals what
[`md_fetch_tranches()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish_tranches.md)
would still have to download. `md_tranche_manifest()` returns the
build's whole manifest: the build id, when and from which commit it was
built, the normalizer signature, the database fingerprint and the file
list. `md_tranche_diff()` compares two builds file by file, which is
what a user needs before updating: which files changed, how many rows
each gained or lost, and whether the normalizer changed.
`md_tranches_prune()` deletes the parquet files of builds no longer in
use, keeping their manifests as the record of what was once here.

## Usage

``` r
md_tranches(
  spec = NULL,
  build = NULL,
  remote = md_remote(),
  root = md_path("tranches"),
  local = FALSE
)

md_tranche_manifest(
  build = NULL,
  remote = md_remote(),
  root = md_path("tranches"),
  local = FALSE
)

md_tranche_diff(
  old,
  new = NULL,
  remote = md_remote(),
  root = md_path("tranches")
)

md_tranches_prune(keep = 1L, root = md_path("tranches"))
```

## Arguments

- spec:

  An
  [`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md):
  mark and total the files it needs.

- build:

  A build id; by default the newest one (`latest.json`).

- remote:

  The base URL of a matchdb copy.

- root:

  The local tranche directory.

- local:

  Read the local copy of the manifest instead of the remote one.

- old, new:

  Builds to compare: build ids (read from the local copies when here,
  else from the remote) or manifests from `md_tranche_manifest()`. `new`
  defaults to the newest published build.

- keep:

  How many builds to keep whole, newest first. The build `latest.json`
  names is always kept.

## Value

`md_tranches()`: a data frame of class `md_tranches`, one row per file:
`table`, `layer`, `variant_class`, `rows`, `mb`, `here` and, given a
spec, `needed`. The manifest's build fields ride along as attributes.

`md_tranche_manifest()`: the manifest as a list; `files` is a data frame
with `path`, `table`, `layer`, `variant_class`, `rows`, `bytes`, `md5`.

`md_tranche_diff()`: a data frame of class `md_tranche_diff`, one row
per file in either build: `status` (`same`, `changed`, `added`,
`removed`), `rows_old`, `rows_new`, `mb_new`. The two builds' fields are
attributes `old` and `new`.

`md_tranches_prune()`: the bytes freed, invisibly.

## Updating

A new build is a new folder; nothing in an old one is overwritten. Rows
are not layered in: the derived columns, statistics cells, clusters and
compact tables are rebuilt over the whole database for every build, so a
new release changes files whose source rows did not change. What can be
saved is the download:
[`md_fetch_tranches()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish_tranches.md)
copies any file whose md5 matches one already in an older local build
instead of downloading it again, and `md_tranche_diff()` says how much
that will be beforehand.

## Examples

``` r
if (FALSE) { # \dontrun{
md_tranches()                                   # everything in the newest build
md_tranches(md_spec(layers = "bmf_active"))     # what one spec would download
md_tranche_manifest()$normalize_signature
md_tranche_diff("2026-10-27-82c6f0cb")          # that build against the newest
} # }
```
