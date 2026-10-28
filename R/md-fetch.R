#' Download published references, or the whole database
#'
#' Most users never build matchdb. They download a compiled reference - a few
#' hundred megabytes - and match against it. `md_fetch_reference()` copies a
#' published bundle from the remote into the local publish directory, where
#' [md_reference()] reads it; `md_reference(fetch = TRUE)` does both.
#' `md_fetch_db()` downloads the full database (about 10 GB) for those who
#' want to compile their own slices with [md_spec()] and [md_compile()], or
#' browse it with [md_lookup()] and [md_cluster()]. Between the two,
#' [md_fetch_tranches()] downloads only the parquet files one spec needs.
#'
#' @section The remote:
#' The default is the public NCCS copy,
#' `https://nccs-efile.s3.amazonaws.com/dev/matchdb`, read over plain HTTPS: no
#' AWS account or credentials are needed. Set `options(matchdb.remote = ...)`
#' to use another copy; any URL [utils::download.file()] can read works,
#' including `file://` paths.
#'
#' Every file is checked against the md5 recorded when it was published (the
#' bundle's `stamp.json`, the database's `MANIFEST.json`), and a file that does
#' not match is deleted rather than kept.
#'
#' @param label A published label: `active-legal`, `active-observed`,
#'   `unified-legal` or `unified-observed`.
#' @param spec_hash A specific bundle; by default the one the remote's
#'   `latest.json` points at.
#' @param remote The base URL of a matchdb copy (holding `MATCHDB.duckdb` and
#'   `publish/`).
#' @param root The local publish directory.
#' @param overwrite Download again even if the bundle is already here and
#'   intact.
#' @return `md_fetch_reference()`: the local bundle directory, invisibly.
#' @examples
#' \dontrun{
#' md_fetch_reference("active-observed")
#' b <- md_reference("active-observed")
#'
#' # or in one step
#' b <- md_reference("active-observed", fetch = TRUE)
#' }
#' @export
md_fetch_reference <- function(label, spec_hash = NULL, remote = md_remote(),
                               root = md_path("publish"), overwrite = FALSE) {
  base <- paste0(sub("/+$", "", remote), "/publish")
  if (is.null(spec_hash)) {
    latest <- jsonlite::fromJSON(.md_download_text(paste0(base, "/latest.json")))
    if (is.null(latest[[label]])) {
      stop(sprintf("nothing is published as %s at %s; published: %s", label, remote,
                   paste(names(latest), collapse = ", ")), call. = FALSE)
    }
    spec_hash <- latest[[label]]$spec_hash
  }
  url <- sprintf("%s/%s/%s", base, label, spec_hash)
  dir <- file.path(root, label, spec_hash)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  stamp_txt <- .md_download_text(paste0(url, "/stamp.json"))
  stamp <- jsonlite::fromJSON(stamp_txt, simplifyVector = FALSE)
  for (fn in names(stamp$files)) {
    dest <- file.path(dir, fn)
    if (!overwrite && file.exists(dest) &&
        identical(unname(tools::md5sum(dest)), stamp$files[[fn]])) next
    message(sprintf("fetching %s/%s/%s", label, spec_hash, fn))
    .md_download(paste0(url, "/", fn), dest, md5 = stamp$files[[fn]])
  }
  writeLines(stamp_txt, file.path(dir, "stamp.json"), useBytes = TRUE)
  # the local latest.json follows what was fetched, so md_reference(label) finds it
  md_publish_pointer(label, spec_hash, root)
  invisible(dir)
}

#' @rdname md_fetch_reference
#' @param dest Where to put the database. The default is where [md_db()]
#'   looks.
#' @return `md_fetch_db()`: the local database path, invisibly.
#' @export
md_fetch_db <- function(remote = md_remote(), dest = md_path("db", "MATCHDB.duckdb"),
                        overwrite = FALSE) {
  base <- sub("/+$", "", remote)
  man_txt <- .md_download_text(paste0(base, "/MANIFEST.json"))
  man <- jsonlite::fromJSON(man_txt, simplifyVector = FALSE)
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  if (!overwrite && file.exists(dest) && isTRUE(file.size(dest) == man$size_bytes) &&
      identical(unname(tools::md5sum(dest)), man$md5)) {
    message("the database at ", dest, " is already this build")
  } else {
    message(sprintf("fetching MATCHDB.duckdb (%.1f GB, built %s from matchdb@%s)",
                    man$size_bytes / 1e9, man$built, substr(man$matchdb_commit, 1, 7)))
    .md_download(paste0(base, "/", man$database), dest, md5 = man$md5)
  }
  writeLines(man_txt, file.path(dirname(dest), "MANIFEST.json"), useBytes = TRUE)
  invisible(dest)
}

#' @rdname md_fetch_reference
#' @export
md_remote <- function() {
  getOption("matchdb.remote", "https://nccs-efile.s3.amazonaws.com/dev/matchdb")
}

.md_download <- function(url, dest, md5 = NULL) {
  tmp <- paste0(dest, ".part")
  on.exit(unlink(tmp), add = TRUE)
  old <- options(timeout = max(3600, getOption("timeout"))); on.exit(options(old), add = TRUE)
  status <- tryCatch(utils::download.file(url, tmp, mode = "wb", quiet = TRUE),
                     error = function(e) stop("could not download ", url, ": ",
                                              conditionMessage(e), call. = FALSE))
  if (!identical(status, 0L)) stop("could not download ", url, call. = FALSE)
  if (!is.null(md5) && !identical(unname(tools::md5sum(tmp)), md5)) {
    stop(sprintf("%s does not match its recorded md5; not kept", basename(dest)), call. = FALSE)
  }
  if (file.exists(dest)) unlink(dest)
  if (!file.rename(tmp, dest)) {
    if (!file.copy(tmp, dest, overwrite = TRUE)) stop("could not write ", dest, call. = FALSE)
  }
  invisible(dest)
}

.md_download_text <- function(url) {
  tmp <- tempfile(); on.exit(unlink(tmp))
  .md_download(url, tmp)
  paste(readLines(tmp, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
}
