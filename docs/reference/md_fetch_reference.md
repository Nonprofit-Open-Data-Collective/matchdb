# Download published references, or the whole database

Most users never build matchdb. They download a compiled reference - a
few hundred megabytes - and match against it. `md_fetch_reference()`
copies a published bundle from the remote into the local publish
directory, where
[`md_reference()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
reads it; `md_reference(fetch = TRUE)` does both. `md_fetch_db()`
downloads the full database (about 10 GB) for those who want to compile
their own slices with
[`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md)
and
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md),
or browse it with
[`md_lookup()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_lookup.md)
and
[`md_cluster()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_cluster.md).

## Usage

``` r
md_fetch_reference(
  label,
  spec_hash = NULL,
  remote = md_remote(),
  root = md_path("publish"),
  overwrite = FALSE
)

md_fetch_db(
  remote = md_remote(),
  dest = md_path("db", "MATCHDB.duckdb"),
  overwrite = FALSE
)

md_remote()
```

## Arguments

- label:

  A published label: `active-legal`, `active-observed`, `unified-legal`
  or `unified-observed`.

- spec_hash:

  A specific bundle; by default the one the remote's `latest.json`
  points at.

- remote:

  The base URL of a matchdb copy (holding `MATCHDB.duckdb` and
  `publish/`).

- root:

  The local publish directory.

- overwrite:

  Download again even if the bundle is already here and intact.

- dest:

  Where to put the database. The default is where
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md)
  looks.

## Value

`md_fetch_reference()`: the local bundle directory, invisibly.

`md_fetch_db()`: the local database path, invisibly.

## The remote

The default is the public NCCS copy,
`https://nccs-efile.s3.amazonaws.com/dev/matchdb`, read over plain
HTTPS: no AWS account or credentials are needed. Set
`options(matchdb.remote = ...)` to use another copy; any URL
[`utils::download.file()`](https://rdrr.io/r/utils/download.file.html)
can read works, including `file://` paths.

Every file is checked against the md5 recorded when it was published
(the bundle's `stamp.json`, the database's `MANIFEST.json`), and a file
that does not match is deleted rather than kept.

## Examples

``` r
if (FALSE) { # \dontrun{
md_fetch_reference("active-observed")
b <- md_reference("active-observed")

# or in one step
b <- md_reference("active-observed", fetch = TRUE)
} # }
```
