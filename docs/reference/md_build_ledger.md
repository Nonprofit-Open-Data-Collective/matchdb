# Load the pinned source files into the ledger

Walks the sources that write names or addresses, finds each one's pinned
files under `sources/<source>/<version>/`, parses each with its
`md_parse_*()` function and applies it with
[`md_apply_release()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_apply_release.md):
one release per file, so a year-partitioned source is one partition per
year. Each file's md5 comes from the pin's `FILES.csv` when there is
one, so a file already applied is skipped on the next run.

## Usage

``` r
md_build_ledger(con, versions, sources = NULL)
```

## Arguments

- con:

  A DuckDB connection.

- versions:

  A named list of versions, as in `dev/build-versions.R`.

- sources:

  Restrict to these sources. Default: every source above.

## Value

A data frame, one row per release, from
[`md_apply_release()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_apply_release.md).

## Details

|  |  |  |
|----|----|----|
| source | version key | files |
| `bmf_unified` | `bmf_unified` | the pinned parquet |
| `efile_header`, `schedi`, `efile_related`, `efile_affiliate_listing` | `efile` | the published table, one `<TABLE>-YYYY.CSV` per tax year |
| `f1023ez` | `f1023ez` | `f1023ez-approvals-YYYY.csv`, the CSVs [`md_ingest_f1023ez()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_f1023ez.md) converts the workbooks to |
| `e_postcard` | `e_postcard` | `*-E-POSTCARD.csv` |
| `revocations` | `revocations` | `*-REVOCATIONS-ORGS.csv` |
| `address_crosswalk` | `address_crosswalk` | the pinned CSV |
| `bmf_active` | `bmf_active` | the pinned CSV, only if a version is given |

A source whose version is missing from `versions`, or whose files are
not there, is skipped with a message rather than failing the run.
