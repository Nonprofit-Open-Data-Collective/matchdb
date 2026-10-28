#' Where matchdb keeps its data
#'
#' The build handles multi-gigabyte sources and produces a database of similar
#' size, so nothing lives in the package repository. `md_data_root()` resolves
#' the root in this order: the `MATCHDB_DATA` environment variable, then
#' `~/Documents/matchdb`.
#'
#' The layout under the root is fixed, because provenance depends on it:
#'
#' \describe{
#'   \item{`sources/<source>/<version>/`}{one pinned, immutable copy of an
#'     upstream file. Never overwritten - a new upstream release is a new
#'     version directory. See [md_source_pin()].}
#'   \item{`db/`}{`MATCHDB.duckdb`, the relational source of truth.}
#'   \item{`publish/<label>/<spec_hash>/`}{compiled references
#'     ([md_publish()]).}
#'   \item{`tranches/<build>/`}{the database as parquet, split by layer and
#'     class ([md_publish_tranches()]).}
#'   \item{`logs/`}{the workspace log: `runs-index.csv` (one row per fetch,
#'     compile or publish, never rewritten), one detail file per run, and
#'     `state.json` (what is here now). See [md_log()].}
#'   \item{`work/`}{scratch. Safe to delete; never an input to anything.}
#' }
#'
#' @param ... Path components appended to the root.
#' @param create Create the directory if it does not exist.
#' @return A normalized absolute path.
#' @export
md_data_root <- function() {
  root <- Sys.getenv("MATCHDB_DATA", unset = "")
  if (!nzchar(root)) root <- file.path(path.expand("~"), "Documents", "matchdb")
  root
}

#' @rdname md_data_root
#' @export
md_path <- function(..., create = FALSE) {
  p <- file.path(md_data_root(), ...)
  if (create) dir.create(p, recursive = TRUE, showWarnings = FALSE)
  p
}

#' @rdname md_data_root
#' @export
md_data_init <- function(quiet = FALSE) {
  root <- md_data_root()
  for (d in c("sources", "db", "publish", "tranches", "logs", "work")) {
    dir.create(file.path(root, d), recursive = TRUE, showWarnings = FALSE)
  }
  if (!quiet) message("matchdb data root: ", root)
  invisible(root)
}
