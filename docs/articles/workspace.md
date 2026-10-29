# Your matchdb folder: downloads, the log, and updates

Everything matchdb downloads or writes goes in one folder. This article
covers:

- what goes in that folder;
- the three ways to get data, and what each costs;
- the log of everything fetched, compiled and published;
- updating to a new release, and finding out why match results moved.

## One folder

The folder is
[`md_data_root()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_data_root.md).
It is the `MATCHDB_DATA` environment variable if you set one, and
`~/Documents/matchdb` otherwise. Set it in `.Renviron` to keep the data
on a larger drive:

    MATCHDB_DATA=D:/matchdb

Its layout is fixed:

    matchdb/
      tranches/<build>/        the database as parquet, split by layer and class
      tranches/latest.json     the build md_tranche_db() opens by default
      publish/<label>/<hash>/  compiled references (bundles)
      db/MATCHDB.duckdb        the whole database, if you download it
      logs/runs-index.csv      one row per action, never rewritten
      logs/<kind>-<run>.csv    the detail of one action
      logs/state.json          what is here now

## Three ways to get data

| you want | call | download |
|----|----|---:|
| one of the four published tiers | `md_reference("active-observed", fetch = "missing")` | 230–400 MB |
| your own spec | `md_fetch_tranches(spec)` | about 1 GB for an active-layer spec |
| everything, to browse | [`md_fetch_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_fetch_reference.md) | 11.7 GB |

For your own spec, see what it will cost first.
[`md_tranches()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_tranches.md)
reads the published build’s manifest and marks the files the spec needs:

``` r

s <- md_spec(layers = "bmf_active", names = c("legal", "dba"), addresses = "mailing")
md_tranches(s)
#> <md_tranches 2026-10-27-82c6f0cb> built 2026-10-27 from matchdb@592b078, normalizer v1-3e7b9f9d59bbb19e
#>   108 files, 4.64 GB; here: 0 files, 0.00 GB
#>   this spec needs 17 files, 1.03 GB; still to download: 17 files, 1.03 GB
#>              table         layer files     rows    mb here
#>            address    bmf_active     3 13568639 856.1    0
#>   ...
```

Then fetch those files, open them, and compile:

``` r

md_fetch_tranches(s)
con <- md_tranche_db()
r <- md_compile(s, con)          # 2,742,924 rows, about a minute
md_db_close(con)
```

[`md_tranche_manifest()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_tranches.md)
returns the build’s whole manifest: \* the build id; \* when it was
built, and from which matchdb commit; \* the normalizer it was built
with, and the npnormalize and npmatch versions; \* every file’s rows,
bytes and md5.

A copy of the manifest is kept in the build’s folder. It records what
you downloaded, even after the files themselves are deleted.

### Why parquet files, and not a local database

The downloaded parquet files are the local copy.
[`md_tranche_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish_tranches.md)
opens them in an in-memory DuckDB, as one view per table, and copies
nothing. matchdb does not build a second database from them, for three
reasons:

- Each file can be checked against its md5, alone. A database built from
  them could only be checked as a whole.
- A second spec adds only the files it is missing, and a new release
  reuses every file that did not change. A database would have to be
  rebuilt.
- Compiling from the files takes about a minute, so a database would
  save little time and double the disk used.

What is worth saving is the compiled reference.
[`md_publish()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
writes it as a bundle under `publish/`, and
[`md_reference()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
reads it back in seconds.

## The log

Every fetch, compile and publish adds one row to `logs/runs-index.csv`.
Rows are never changed or removed. Each row records: \* what was done,
and when; \* the tranche build and spec; \* how many files were
downloaded, copied from an older build, reused or failed, and the bytes
moved; \* the installed matchdb, npnormalize, npmatch and normalizer
signature.

``` r

md_log()
#>                  run_id           kind               build        spec_hash files downloaded      bytes
#>  20261027T184905-5f4419 fetch_tranches 2026-10-27-82c6f0cb 2402137493f88c8e    17         17 1028259600
#>  20261027T185000-5f4479        compile 2026-10-27-82c6f0cb 2402137493f88c8e    NA         NA         NA
```

[`md_log_run()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_log.md)
returns one action’s detail. For a fetch, that is every file with its
source URL, status, rows, bytes and md5, plus the manifest it came from.
For a compile, it is the spec, the stamp and the shape of the result:

``` r

md_log_run("20261027T184905-5f4419")
```

[`md_status()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_log.md)
describes what is here now. It covers the installed versions, the
current build and how much of it is downloaded, the database, the
bundles, and the last compile. The same record is written to
`logs/state.json` after every action:

``` r

md_status()
#> <md_status> D:/matchdb
#>   installed  matchdb 0.1.1.9000, npnormalize 0.1.0, npmatch 0.1.1.9000, normalizer v1-3e7b9f9d59bbb19e
#>   tranches   2026-10-27-82c6f0cb (built 2026-10-27, normalizer v1-3e7b9f9d59bbb19e): 17 of 108 files here, 1.03 GB
#>   database   none
#>   last compile 2026-10-27T18:50:00: spec 2402137493f88c8e, 2,742,924 rows, from tranches 2026-10-27-82c6f0cb
```

## Updating to a new release

A new release is a new build, in a new folder. Nothing in the old one is
overwritten. To see what changed before downloading anything:

``` r

md_tranche_diff("2026-10-27-82c6f0cb")      # your build against the newest
```

The diff lists: \* every file as same, changed, added or removed, with
its change in rows; \* whether the normalizer, the npnormalize or
npmatch version, or the matchdb commit changed; \* how much a full
update would download.

Then fetch as before. Files whose md5 matches one in your older build
are copied from it rather than downloaded:

``` r

md_fetch_tranches(s)
#> (an illustration: the first later build will be the first real case)
#> tranches 2026-11-30-...: 17 files here (0 already were, 14 copied from an older build), 0.21 GB downloaded
```

Rows are not added to old files. Every build recomputes, over the whole
database: \* the normalized columns; \* the statistics cells; \* the
clusters and the compact tables.

So a release can change a file whose own rows did not change. Copying
unchanged files saves the downloads that can be saved, and the whole
build always stays consistent.

When the new build works,
[`md_tranches_prune()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_tranches.md)
deletes the old build’s parquet files and keeps its manifest:

``` r

md_tranches_prune(keep = 1)
```

## When match results change

A match can move for two reasons: \* the data changed: a new build; \*
the matching changed: a new npnormalize or npmatch, above all a new
normalizer.

The log records both. Before each action it compares the installed
npnormalize, npmatch and normalizer with what the last action used. If
they differ, it adds a `version_change` row first. Fetching a different
build or database adds one too:

``` r

md_log("version_change")
#> (an illustration of the two kinds of row)
#>   kind           recorded_at              note
#>   version_change 2026-11-30T09:12:41-0700 tranches 2026-10-27-82c6f0cb -> 2026-11-30-...: files same 94 changed 14 ...
#>   version_change 2026-12-02T15:03:10-0700 normalize_signature v1-3e7b9f9d59bbb19e -> v1-...
```

Read these rows next to the compiles around them. They show which build
and which normalizer produced each set of results.

A build made by another normalizer is refused rather than used:
[`md_tranche_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish_tranches.md)
and
[`md_reference()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_publish.md)
stop with an error naming both signatures. Install the matching
npnormalize, or fetch a build made with yours.

To turn logging off, set `options(matchdb.log = FALSE)`.
