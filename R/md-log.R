#' The workspace log: what was fetched, compiled and published, and when
#'
#' Everything matchdb downloads or writes lives under one folder,
#' [md_data_root()]. Its `logs/` folder records each action:
#' \describe{
#'   \item{`logs/runs-index.csv`}{One row per action, appended and never
#'     edited: `run_id`, `kind`, `recorded_at`, `build`, `spec_hash`, counts
#'     of files downloaded, copied, reused and failed, `bytes`,
#'     `elapsed_seconds`, the installed `matchdb_version`,
#'     `npnormalize_version`, `npnormalize_commit`, `npmatch_version`,
#'     `npmatch_commit` and `normalize_signature`, a `note`, and `log_file`.
#'     An index written by a matchdb before npnormalize is rewritten once, to
#'     add the npnormalize columns, the next time an action is logged.}
#'   \item{`logs/<kind>-<run_id>.csv` or `.json`}{The detail of one action. A
#'     fetch lists every file with its status, size and md5, and the manifest it
#'     came from. A compile records the spec, the stamp and the report's
#'     shape.}
#'   \item{`logs/state.json`}{The current state, rewritten after every action:
#'     the installed versions, the current tranche build and what of it is
#'     here, the database and the bundles present, and the last compile.}
#' }
#' This follows panel990's `logs/` folder (`runs-index.csv` plus one file per
#' run), adding the versions and a current-state record.
#'
#' @section When versions change:
#' Before recording an action, the log compares the installed npnormalize,
#' npmatch and normalizer signature with what `state.json` last recorded. A difference adds
#' a `version_change` row first, saying what changed. Fetching a new tranche
#' build, or a different database, adds one too. Match results can move when
#' the normalizer or the data moves, and these rows are what to read when they
#' do: the history says when, and `md_tranche_diff()` says what.
#'
#' Logging never stops an action: a log that cannot be written is a warning.
#' `options(matchdb.log = FALSE)` turns it off.
#'
#' @param kind Only rows of these kinds: `fetch_tranches`, `fetch_db`,
#'   `fetch_reference`, `compile`, `publish`, `publish_tranches`, `prune`,
#'   `version_change`.
#' @param n Only the last `n` rows.
#' @return `md_log()`: the runs index as a data frame, oldest first, or `NULL`
#'   when nothing has been logged.
#' @examples
#' \dontrun{
#' md_log()                          # every action, oldest first
#' md_log("version_change")          # when the data or the normalizer changed
#' md_log_run(md_log(n = 1)$run_id)  # the files the last action touched
#' md_status()                       # what is here now
#' }
#' @export
md_log <- function(kind = NULL, n = NULL) {
  f <- file.path(.md_log_dir(), "runs-index.csv")
  if (!file.exists(f)) { message("nothing logged yet under ", .md_log_dir()); return(invisible(NULL)) }
  d <- utils::read.csv(f, stringsAsFactors = FALSE, colClasses = c(note = "character"))
  if (!is.null(kind)) d <- d[d$kind %in% kind, , drop = FALSE]
  if (!is.null(n)) d <- utils::tail(d, n)
  rownames(d) <- NULL
  d
}

#' @rdname md_log
#' @param run_id A run id from `md_log()`.
#' @return `md_log_run()`: that action's detail, a data frame (fetches) or a
#'   list (compiles and the rest).
#' @export
md_log_run <- function(run_id) {
  f <- Sys.glob(file.path(.md_log_dir(), sprintf("*-%s.*", run_id)))
  if (!length(f)) stop("no detail logged for run ", run_id, call. = FALSE)
  if (grepl("[.]csv$", f[1])) utils::read.csv(f[1], stringsAsFactors = FALSE)
  else jsonlite::read_json(f[1], simplifyVector = TRUE)
}

#' @rdname md_log
#' @return `md_status()`: the current state (what `logs/state.json` holds), as
#'   a list of class `md_status`. It is recomputed from what is on disk, and
#'   `state.json` is refreshed with it.
#' @export
md_status <- function() {
  st <- .md_state(.md_state_read())
  .md_state_save(st)
  structure(st, class = "md_status")
}

#' @export
print.md_status <- function(x, ...) {
  i <- x$installed
  cat(sprintf("<md_status> %s\n", x$data_root))
  at <- function(commit) if (is.na(commit %||% NA)) "" else paste0(" @", substr(commit, 1, 7))
  cat(sprintf("  installed  matchdb %s, npnormalize %s%s, npmatch %s%s, normalizer %s\n",
              i$matchdb_version, i$npnormalize_version %||% NA, at(i$npnormalize_commit),
              i$npmatch_version %||% "not installed", at(i$npmatch_commit),
              i$normalize_signature))
  t <- x$tranches
  if (is.null(t$build)) cat("  tranches   none\n") else {
    cat(sprintf("  tranches   %s (built %s, normalizer %s): %d of %d files here, %.2f GB%s\n",
                t$build, substr(t$built, 1, 10), t$normalize_signature, t$files_here, t$files,
                t$gb_here, if (identical(t$normalize_signature, i$normalize_signature)) "" else
                  "  ** not the installed normalizer **"))
    if (length(t$other_builds)) cat("             older builds here:", paste(t$other_builds, collapse = ", "), "\n")
  }
  d <- x$database
  if (isTRUE(d$present)) {
    cat(sprintf("  database   %s, %.1f GB, built %s from matchdb@%s\n", d$path, d$gb,
                d$built %||% "?", substr(d$matchdb_commit %||% "?", 1, 7)))
  } else cat("  database   none\n")
  if (length(x$references)) {
    cat("  references", paste(sprintf("%s (%s, %s rows)", names(x$references),
                                      vapply(x$references, `[[`, "", "spec_hash"),
                                      vapply(x$references, function(r) format(r$rows, big.mark = ","), "")),
                              collapse = "; "), "\n")
  }
  if (!is.null(x$last_compile)) {
    l <- x$last_compile
    cat(sprintf("  last compile %s: spec %s, %s rows, from %s\n", substr(l$recorded_at, 1, 19),
                l$spec_hash, format(l$rows, big.mark = ","), l$source))
  }
  if (!is.null(x$last_action)) {
    cat(sprintf("  last action  %s %s (run %s)\n", substr(x$last_action$recorded_at, 1, 19),
                x$last_action$kind, x$last_action$run_id))
  }
  invisible(x)
}

## ---- writing ----------------------------------------------------------------------

.md_log_dir <- function() md_path("logs")

.md_run_id <- function() {
  # tempfile() rather than the RNG, so logging never moves the random seed
  paste0(format(Sys.time(), "%Y%m%dT%H%M%S"), "-", substr(sub("^file", "", basename(tempfile())), 1, 6))
}

.md_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")

.md_installed <- function() {
  list(matchdb_version = as.character(utils::packageVersion("matchdb")),
       npnormalize_version = .md_pkg_version("npnormalize"),
       npnormalize_commit = .md_pkg_commit("npnormalize"),
       npmatch_version = .md_pkg_version("npmatch"),
       npmatch_commit = .md_pkg_commit("npmatch"),
       normalize_signature = tryCatch(npnormalize::np_normalize_signature(),
                                      error = function(e) NA_character_))
}

.md_log_cols <- c("run_id", "kind", "recorded_at", "build", "spec_hash", "files", "downloaded",
                  "copied", "reused", "failed", "bytes", "elapsed_seconds", "matchdb_version",
                  "npnormalize_version", "npnormalize_commit", "npmatch_version",
                  "npmatch_commit", "normalize_signature", "note", "log_file")

# Record one action. `files` is a per-file data frame (written as the run's CSV)
# and `detail` a list (written as its JSON); either may be NULL. Never throws.
.md_log <- function(kind, build = NA, spec_hash = NA, files = NULL, detail = NULL, note = "",
                    bytes = NA, elapsed = NA, run_id = .md_run_id(), last_compile = NULL) {
  if (!isTRUE(getOption("matchdb.log", TRUE))) return(invisible(NULL))
  tryCatch({
    dir <- .md_log_dir(); dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    prev <- .md_state_read()
    inst <- .md_installed()
    .md_log_version_change(prev$installed, inst)
    log_file <- ""
    if (!is.null(files) && nrow(files)) {
      log_file <- sprintf("%s-%s.csv", kind, run_id)
      utils::write.csv(cbind(run_id = run_id, files, stringsAsFactors = FALSE),
                       file.path(dir, log_file), row.names = FALSE)
    } else if (!is.null(detail)) {
      log_file <- sprintf("%s-%s.json", kind, run_id)
      jsonlite::write_json(detail, file.path(dir, log_file), auto_unbox = TRUE, pretty = TRUE,
                           digits = NA, na = "null", null = "null")
    }
    # a manifest row is a record of where the files came from, not a file fetched
    st <- if (is.null(files) || !nrow(files)) NULL else files$status[files$status != "manifest"]
    cnt <- function(s) if (is.null(st)) NA_integer_ else sum(st == s)
    if (is.na(bytes) && !is.null(st) && "bytes" %in% names(files)) {
      bytes <- sum(files$bytes[files$status %in% c("downloaded", "copied")], na.rm = TRUE)
    }
    .md_log_append(list(run_id = run_id, kind = kind, recorded_at = .md_now(),
                        build = build %||% NA, spec_hash = spec_hash %||% NA,
                        files = if (is.null(st)) NA_integer_ else length(st),
                        downloaded = cnt("downloaded"), copied = cnt("copied"),
                        reused = cnt("reused"), failed = cnt("failed"), bytes = bytes,
                        elapsed_seconds = if (is.na(elapsed)) NA else round(elapsed, 1),
                        matchdb_version = inst$matchdb_version,
                        npnormalize_version = inst$npnormalize_version,
                        npnormalize_commit = inst$npnormalize_commit,
                        npmatch_version = inst$npmatch_version,
                        npmatch_commit = inst$npmatch_commit,
                        normalize_signature = inst$normalize_signature,
                        note = note, log_file = log_file))
    if (!is.null(last_compile)) prev$last_compile <- c(list(run_id = run_id, recorded_at = .md_now()),
                                                       last_compile)
    st <- .md_state(prev)
    st$last_action <- list(run_id = run_id, kind = kind, recorded_at = .md_now())
    .md_state_save(st)
  }, error = function(e) warning("matchdb could not write its log: ", conditionMessage(e),
                                 call. = FALSE))
  invisible(run_id)
}

.md_log_append <- function(row) {
  f <- file.path(.md_log_dir(), "runs-index.csv")
  had <- file.exists(f)
  if (had) .md_log_upgrade(f)
  row <- as.data.frame(lapply(row[.md_log_cols], function(v) if (is.null(v)) NA else v),
                       stringsAsFactors = FALSE)
  utils::write.table(row, f, sep = ",", append = had, col.names = !had, row.names = FALSE,
                     qmethod = "double")
}

# An index written by an older matchdb has fewer columns. Rows are appended
# without a header, so before the first append rewrite it once with the current
# columns, the new ones empty in the old rows.
.md_log_upgrade <- function(f) {
  head <- names(utils::read.csv(f, nrows = 1L, check.names = FALSE))
  if (identical(head, .md_log_cols)) return(invisible(FALSE))
  d <- utils::read.csv(f, stringsAsFactors = FALSE, colClasses = "character",
                       check.names = FALSE)
  for (k in setdiff(.md_log_cols, names(d))) d[[k]] <- rep(NA_character_, nrow(d))
  d <- d[c(.md_log_cols, setdiff(names(d), .md_log_cols))]
  utils::write.csv(d, f, row.names = FALSE, na = "NA")
  invisible(TRUE)
}

# A version_change row when the installed matchdb, npnormalize, npmatch or
# normalizer is not what the last recorded action ran with.
.md_log_version_change <- function(was, now) {
  if (is.null(was)) return(invisible())
  ch <- character()
  for (k in c("normalize_signature", "npnormalize_commit", "npnormalize_version",
              "npmatch_commit", "npmatch_version", "matchdb_version")) {
    a <- was[[k]] %||% NA; b <- now[[k]] %||% NA
    if (!identical(as.character(a), as.character(b))) ch <- c(ch, sprintf("%s %s -> %s", k, a, b))
  }
  if (length(ch)) .md_log_version_row(paste(ch, collapse = "; "))
  invisible()
}

.md_log_version_row <- function(note, build = NA) {
  inst <- .md_installed()
  .md_log_append(list(run_id = .md_run_id(), kind = "version_change", recorded_at = .md_now(),
                      build = build, spec_hash = NA, files = NA, downloaded = NA, copied = NA,
                      reused = NA, failed = NA, bytes = NA, elapsed_seconds = NA,
                      matchdb_version = inst$matchdb_version,
                      npnormalize_version = inst$npnormalize_version,
                      npnormalize_commit = inst$npnormalize_commit,
                      npmatch_version = inst$npmatch_version,
                      npmatch_commit = inst$npmatch_commit,
                      normalize_signature = inst$normalize_signature, note = note, log_file = ""))
}

## ---- state ------------------------------------------------------------------------

.md_state_read <- function() {
  f <- file.path(.md_log_dir(), "state.json")
  if (!file.exists(f)) return(NULL)
  tryCatch(jsonlite::read_json(f, simplifyVector = TRUE), error = function(e) NULL)
}

.md_state_save <- function(st) {
  dir.create(.md_log_dir(), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(st, file.path(.md_log_dir(), "state.json"), auto_unbox = TRUE,
                       pretty = TRUE, digits = NA, na = "null", null = "null")
}

# What is here now, from disk; the last compile and action carried from `prev`.
.md_state <- function(prev = NULL) {
  st <- list(updated = .md_now(), data_root = md_data_root(), installed = .md_installed())
  troot <- md_path("tranches")
  st$tranches <- list()
  lj <- file.path(troot, "latest.json")
  if (file.exists(lj)) {
    b <- jsonlite::read_json(lj)$build
    mf <- file.path(troot, b, "manifest.json")
    if (file.exists(mf)) {
      m <- jsonlite::fromJSON(mf)
      p <- file.path(troot, b, m$files$path)
      here <- .md_tranche_here(p, m$files$bytes)
      st$tranches <- list(build = b, built = m$built, matchdb_commit = m$matchdb_commit,
                          normalize_signature = m$normalize_signature,
                          db_fingerprint = m$db_fingerprint, files = nrow(m$files),
                          files_here = sum(here), gb_here = round(sum(m$files$bytes[here]) / 1e9, 2),
                          tables_here = sort(unique(m$files$table[here])),
                          other_builds = setdiff(.md_tranche_local_builds(troot)$build, b))
    }
  }
  db <- md_path("db", "MATCHDB.duckdb")
  st$database <- list(present = file.exists(db))
  if (file.exists(db)) {
    st$database$path <- db
    st$database$gb <- round(file.size(db) / 1e9, 1)
    mf <- md_path("db", "MANIFEST.json")
    if (file.exists(mf)) {
      m <- jsonlite::read_json(mf)
      st$database[c("built", "matchdb_commit", "md5")] <- list(m$built, m$matchdb_commit, m$md5)
    }
  }
  pj <- md_path("publish", "latest.json")
  st$references <- list()
  if (file.exists(pj)) {
    for (lab in names(jsonlite::read_json(pj))) {
      h <- jsonlite::read_json(pj)[[lab]]$spec_hash
      sf <- md_path("publish", lab, h, "stamp.json")
      if (file.exists(sf)) {
        s <- jsonlite::read_json(sf)
        st$references[[lab]] <- list(spec_hash = h, rows = s$rows %||% NA,
                                     normalize_signature = s$normalize_signature, built = s$built)
      }
    }
  }
  st$last_compile <- prev$last_compile
  st$last_action <- prev$last_action
  st
}
