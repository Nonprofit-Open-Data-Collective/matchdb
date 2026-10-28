#' What tranches are published, what they cost, and what changed
#'
#' `md_tranches()` lists the files in a tranche build: table, layer, class,
#' rows, size, and whether each is already here. Given a spec, it marks the
#' files [md_compile()] needs for it and totals what [md_fetch_tranches()]
#' would still have to download. `md_tranche_manifest()` returns the build's
#' whole manifest: the build id, when and from which commit it was built, the
#' normalizer signature, the database fingerprint and the file list.
#' `md_tranche_diff()` compares two builds file by file, which is what a user
#' needs before updating: which files changed, how many rows each gained or
#' lost, and whether the normalizer changed. `md_tranches_prune()` deletes the
#' parquet files of builds no longer in use, keeping their manifests as the
#' record of what was once here.
#'
#' @section Updating:
#' A new build is a new folder; nothing in an old one is overwritten. Rows are
#' not layered in: the derived columns, statistics cells, clusters and compact
#' tables are rebuilt over the whole database for every build, so a new
#' release changes files whose source rows did not change. What can be saved
#' is the download: [md_fetch_tranches()] copies any file whose md5 matches one
#' already in an older local build instead of downloading it again, and
#' `md_tranche_diff()` says how much that will be beforehand.
#'
#' @param spec An [md_spec()]: mark and total the files it needs.
#' @param build A build id; by default the newest one (`latest.json`).
#' @param remote The base URL of a matchdb copy.
#' @param root The local tranche directory.
#' @param local Read the local copy of the manifest instead of the remote one.
#' @return `md_tranches()`: a data frame of class `md_tranches`, one row per
#'   file: `table`, `layer`, `variant_class`, `rows`, `mb`, `here` and, given a
#'   spec, `needed`. The manifest's build fields ride along as attributes.
#' @examples
#' \dontrun{
#' md_tranches()                                   # everything in the newest build
#' md_tranches(md_spec(layers = "bmf_active"))     # what one spec would download
#' md_tranche_manifest()$normalize_signature
#' md_tranche_diff("2026-10-27-82c6f0cb")          # that build against the newest
#' }
#' @export
md_tranches <- function(spec = NULL, build = NULL, remote = md_remote(),
                        root = md_path("tranches"), local = FALSE) {
  man <- md_tranche_manifest(build, remote, root, local)
  f <- man$files
  path <- file.path(root, man$build, f$path)
  out <- data.frame(table = f$table, layer = f$layer, variant_class = f$variant_class,
                    rows = f$rows, mb = round(f$bytes / 1e6, 1),
                    here = .md_tranche_here(path, f$bytes),
                    path = f$path, stringsAsFactors = FALSE)
  if (!is.null(spec)) out$needed <- .md_tranche_select(f, spec, NULL)
  for (k in setdiff(names(man), "files")) attr(out, k) <- man[[k]]
  structure(out, class = c("md_tranches", "data.frame"))
}

#' @export
print.md_tranches <- function(x, ...) {
  a <- attributes(x)
  if (is.null(a$build)) { print(as.data.frame(unclass(x)), ...); return(invisible(x)) }  # a subset
  cat(sprintf("<md_tranches %s> built %s from matchdb@%s, normalizer %s\n", a$build,
              substr(a$built, 1, 10), substr(a$matchdb_commit %||% "?", 1, 7),
              a$normalize_signature))
  cat(sprintf("  %d files, %.2f GB; here: %d files, %.2f GB\n", nrow(x), sum(x$mb) / 1e3,
              sum(x$here), sum(x$mb[x$here]) / 1e3))
  if (!is.null(x$needed)) {
    need <- x$needed
    cat(sprintf("  this spec needs %d files, %.2f GB; still to download: %d files, %.2f GB\n",
                sum(need), sum(x$mb[need]) / 1e3, sum(need & !x$here),
                sum(x$mb[need & !x$here]) / 1e3))
  }
  d <- as.data.frame(x)
  d$layer[is.na(d$layer)] <- "(whole)"
  by <- stats::aggregate(cbind(files = 1, rows = d$rows, mb = d$mb, here = d$here) ~
                           table + layer, d, sum)
  by <- by[order(by$table, by$layer), ]
  print(by, row.names = FALSE)
  invisible(x)
}

#' @rdname md_tranches
#' @return `md_tranche_manifest()`: the manifest as a list; `files` is a data
#'   frame with `path`, `table`, `layer`, `variant_class`, `rows`, `bytes`, `md5`.
#' @export
md_tranche_manifest <- function(build = NULL, remote = md_remote(), root = md_path("tranches"),
                                local = FALSE) {
  .md_tranche_parse(.md_tranche_manifest_text(build, remote, root, local))
}

#' @rdname md_tranches
#' @param old,new Builds to compare: build ids (read from the local copies when
#'   here, else from the remote) or manifests from `md_tranche_manifest()`.
#'   `new` defaults to the newest published build.
#' @return `md_tranche_diff()`: a data frame of class `md_tranche_diff`, one row
#'   per file in either build: `status` (`same`, `changed`, `added`, `removed`),
#'   `rows_old`, `rows_new`, `mb_new`. The two builds' fields are attributes
#'   `old` and `new`.
#' @export
md_tranche_diff <- function(old, new = NULL, remote = md_remote(), root = md_path("tranches")) {
  get <- function(b) {
    if (is.list(b)) return(b)
    md_tranche_manifest(b, remote, root,
                        local = !is.null(b) && file.exists(file.path(root, b, "manifest.json")))
  }
  o <- get(old); n <- get(new)
  fo <- o$files; fn <- n$files
  paths <- union(fn$path, fo$path)
  io <- match(paths, fo$path); inn <- match(paths, fn$path)
  status <- ifelse(is.na(io), "added", ifelse(is.na(inn), "removed",
                   ifelse(fo$md5[io] == fn$md5[inn], "same", "changed")))
  d <- data.frame(path = paths, table = ifelse(is.na(inn), fo$table[io], fn$table[inn]),
                  layer = ifelse(is.na(inn), fo$layer[io], fn$layer[inn]),
                  variant_class = ifelse(is.na(inn), fo$variant_class[io], fn$variant_class[inn]),
                  status = status, rows_old = fo$rows[io], rows_new = fn$rows[inn],
                  mb_new = round(fn$bytes[inn] / 1e6, 1), stringsAsFactors = FALSE)
  keep <- function(m) m[setdiff(names(m), "files")]
  structure(d, old = keep(o), new = keep(n), class = c("md_tranche_diff", "data.frame"))
}

#' @export
print.md_tranche_diff <- function(x, ...) {
  o <- attr(x, "old"); n <- attr(x, "new")
  if (is.null(o)) { print(as.data.frame(unclass(x)), ...); return(invisible(x)) }   # a subset
  cat(sprintf("<md_tranche_diff> %s -> %s\n", o$build, n$build))
  for (k in c("normalize_signature", "npnormalize_version", "npmatch_version", "matchdb_commit",
              "db_fingerprint")) {
    a <- o[[k]] %||% "?"; b <- n[[k]] %||% "?"
    cat(sprintf("  %-20s %s%s\n", k, a, if (identical(a, b)) "  (same)" else paste0(" -> ", b)))
  }
  if (!identical(o$normalize_signature, n$normalize_signature)) {
    cat("  The normalizer changed: every derived column may differ, and match results with it.\n")
  }
  s <- table(factor(x$status, c("same", "changed", "added", "removed")))
  cat(sprintf("  files: %s\n", paste(names(s), s, collapse = ", ")))
  cat(sprintf("  to download for the whole build: %.2f GB of %.2f GB\n",
              sum(x$mb_new[x$status %in% c("changed", "added")], na.rm = TRUE) / 1e3,
              sum(x$mb_new, na.rm = TRUE) / 1e3))
  ch <- x[x$status != "same", ]
  if (nrow(ch)) {
    ch$rows_change <- ifelse(is.na(ch$rows_new), 0, ch$rows_new) -
      ifelse(is.na(ch$rows_old), 0, ch$rows_old)
    ch$layer[is.na(ch$layer)] <- "(whole)"
    by <- stats::aggregate(cbind(files = 1, rows_change = ch$rows_change) ~ table + layer + status,
                           ch, sum)
    print(by[order(by$table, by$layer), ], row.names = FALSE)
  }
  invisible(x)
}

#' @rdname md_tranches
#' @param keep How many builds to keep whole, newest first. The build
#'   `latest.json` names is always kept.
#' @return `md_tranches_prune()`: the bytes freed, invisibly.
#' @export
md_tranches_prune <- function(keep = 1L, root = md_path("tranches")) {
  b <- .md_tranche_local_builds(root)
  if (!nrow(b)) return(invisible(0))
  cur <- if (file.exists(file.path(root, "latest.json")))
    jsonlite::read_json(file.path(root, "latest.json"))$build else NA
  b <- b[order(b$built, decreasing = TRUE), ]
  drop <- b$build[-seq_len(min(keep, nrow(b)))]
  drop <- setdiff(drop, cur)
  freed <- 0
  for (d in drop) {
    f <- setdiff(list.files(file.path(root, d), recursive = TRUE, full.names = TRUE),
                 file.path(root, d, "manifest.json"))
    if (!length(f)) next
    sz <- file.size(f); n <- sum(sz); freed <- freed + n
    unlink(f)
    # empty partition folders go too; the manifest stays as the record
    for (s in rev(list.dirs(file.path(root, d), recursive = TRUE, full.names = TRUE)[-1])) {
      if (!length(list.files(s, all.files = TRUE, no.. = TRUE))) unlink(s, recursive = TRUE)
    }
    message(sprintf("pruned %s: %d files, %.2f GB (manifest kept)", d, length(f), n / 1e9))
    .md_log("prune", build = d, bytes = n, note = "parquet deleted; manifest.json kept",
            files = data.frame(path = substring(f, nchar(file.path(root, d)) + 2),
                               status = "deleted", bytes = sz))
  }
  invisible(freed)
}

# The manifest's text, from the local copy or the remote.
.md_tranche_manifest_text <- function(build, remote, root, local) {
  if (local) {
    if (is.null(build)) {
      f <- file.path(root, "latest.json")
      if (!file.exists(f)) stop("no tranches under ", root, "; run md_fetch_tranches()", call. = FALSE)
      build <- jsonlite::read_json(f)$build
    }
    f <- file.path(root, build, "manifest.json")
    if (!file.exists(f)) stop("no tranche build ", build, " under ", root, call. = FALSE)
    return(paste(readLines(f, warn = FALSE, encoding = "UTF-8"), collapse = "\n"))
  }
  base <- paste0(sub("/+$", "", remote), "/tranches")
  if (is.null(build)) build <- jsonlite::fromJSON(.md_download_text(paste0(base, "/latest.json")))$build
  .md_download_text(sprintf("%s/%s/manifest.json", base, build))
}

# Every build with a manifest here, newest first by its built time.
.md_tranche_local_builds <- function(root) {
  m <- Sys.glob(file.path(root, "*", "manifest.json"))
  if (!length(m)) return(data.frame(build = character(), built = character()))
  r <- lapply(m, function(f) { x <- jsonlite::read_json(f); c(build = x$build, built = x$built) })
  d <- as.data.frame(do.call(rbind, r), stringsAsFactors = FALSE)
  d[order(d$built, decreasing = TRUE), ]
}

# Present with the recorded size (the cheap check; md5 is checked on fetch and open).
.md_tranche_here <- function(path, bytes) {
  here <- file.exists(path)
  here[here] <- file.size(path[here]) == bytes[here]
  here
}

# An intact copy of a file with this md5 in another local build, or NULL.
.md_tranche_find_copy <- function(root, md5, bytes, exclude) {
  for (b in setdiff(.md_tranche_local_builds(root)$build, exclude)) {
    m <- jsonlite::fromJSON(file.path(root, b, "manifest.json"))$files
    i <- which(m$md5 == md5)
    for (j in i) {
      p <- file.path(root, b, m$path[j])
      if (.md_tranche_intact(p, bytes, md5)) return(p)
    }
  }
  NULL
}
