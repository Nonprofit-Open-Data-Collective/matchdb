<div id="main" class="col-md-9" role="main">

# The workspace log: what was fetched, compiled and published, and when

<div class="ref-description section level2">

Everything matchdb downloads or writes lives under one folder,
`md_data_root()`. Its `logs/` folder records each action:

-   `logs/runs-index.csv`:

    One row per action, appended and never edited: `run_id`, `kind`,
    `recorded_at`, `build`, `spec_hash`, counts of files downloaded,
    copied, reused and failed, `bytes`, `elapsed_seconds`, the installed
    `matchdb_version`, `npnormalize_version`, `npnormalize_commit`,
    `npmatch_version`, `npmatch_commit` and `normalize_signature`, a
    `note`, and `log_file`. An index written by a matchdb before
    npnormalize is rewritten once, to add the npnormalize columns, the
    next time an action is logged.

-   `logs/<kind>-<run_id>.csv` or `.json`:

    The detail of one action. A fetch lists every file with its status,
    size and md5, and the manifest it came from. A compile records the
    spec, the stamp and the report's shape.

-   `logs/state.json`:

    The current state, rewritten after every action: the installed
    versions, the current tranche build and what of it is here, the
    database and the bundles present, and the last compile.

This follows panel990's `logs/` folder (`runs-index.csv` plus one file
per run), adding the versions and a current-state record.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_log(kind = NULL, n = NULL)

md_log_run(run_id)

md_status()
```

</div>

</div>

<div class="section level2">

## Arguments

-   kind:

    Only rows of these kinds: `fetch_tranches`, `fetch_db`,
    `fetch_reference`, `compile`, `publish`, `publish_tranches`,
    `prune`, `version_change`.

-   n:

    Only the last `n` rows.

-   run_id:

    A run id from `md_log()`.

</div>

<div class="section level2">

## Value

`md_log()`: the runs index as a data frame, oldest first, or `NULL` when
nothing has been logged.

`md_log_run()`: that action's detail, a data frame (fetches) or a list
(compiles and the rest).

`md_status()`: the current state (what `logs/state.json` holds), as a
list of class `md_status`. It is recomputed from what is on disk, and
`state.json` is refreshed with it.

</div>

<div class="section level2">

## When versions change

Before recording an action, the log compares the installed npnormalize,
npmatch and normalizer signature with what `state.json` last recorded. A
difference adds a `version_change` row first, saying what changed.
Fetching a new tranche build, or a different database, adds one too.
Match results can move when the normalizer or the data moves, and these
rows are what to read when they do: the history says when, and
`md_tranche_diff()` says what.

Logging never stops an action: a log that cannot be written is a
warning. `options(matchdb.log = FALSE)` turns it off.

</div>

<div class="section level2">

## Examples

<div class="sourceCode">

``` r
if (FALSE) { # \dontrun{
md_log()                          # every action, oldest first
md_log("version_change")          # when the data or the normalizer changed
md_log_run(md_log(n = 1)$run_id)  # the files the last action touched
md_status()                       # what is here now
} # }
```

</div>

</div>

</div>
