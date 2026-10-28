#' Publish the database as parquet tranches, fetch only what a spec needs
#'
#' The database is one 11.7 GB file, but a custom spec reads a small part of
#' it. `md_publish_tranches()` writes the database as parquet files, split so
#' that a spec can name the files it needs (`PLAN.md` section 7b, tier 2).
#' `md_fetch_tranches()` downloads those files and no others. `md_tranche_db()`
#' opens them as a connection that [md_compile()], [md_publish()] and the
#' lookup functions take in place of [md_db()].
#'
#' @section The layout:
#' A build is `<root>/<build>/`, and `<root>/latest.json` names the current
#' one. The build directory holds:
#' \describe{
#'   \item{`name/<layer>/<variant_class>.parquet`}{the `name` rows of one layer
#'     and class, sorted by EIN}
#'   \item{`name_derived/<layer>/<variant_class>.parquet`}{their derived
#'     columns, split the same way}
#'   \item{`address/...`, `address_derived/...`}{the same for addresses}
#'   \item{`tables/<table>.parquet`}{every other table, whole, sorted by EIN
#'     where it has one}
#'   \item{`manifest.json`}{the build id, the normalizer signature, the
#'     database fingerprint, and for every file its table, layer, class, rows,
#'     bytes and md5}
#' }
#' Derived columns are separate files rather than joined in: `address` and
#' `address_derived` both have `zip5` and `is_po_box`, with different meanings,
#' and separate files keep every table exactly as it is in the database.
#'
#' @section Why layer and class, and not band:
#' Layers partition EINs, and every spec selects by layer and by class, so a
#' file per layer and class lets a spec skip what it does not select. The
#' corroboration band is not split out: most of the 32 statistics cells are
#' small (several under ten rows), and a file per cell would add a download
#' per cell for no gain.
#'
#' @section What a spec needs:
#' `md_compile()` decides each name's class across every class of the selected
#' EINs before it applies the spec's class filter, so a spec needs all of its
#' layers' name files except in-care-of names, which compile never reads. It
#' needs only the address classes it selects. It also needs `entity`,
#' `source_vintage`, the three statistics tables and the two cluster tables.
#' Historical addresses (the largest address class, and in no published tier)
#' are downloaded only by a spec that selects them.
#'
#' @param con A connection from [md_db()].
#' @param root The tranche directory. Defaults to `md_data_root()/tranches`.
#' @param tables Tables to publish. The default is every table except the
#'   observation ledger, which only maintainer code reads.
#' @param commit The matchdb commit the database was built from, recorded in
#'   the manifest.
#' @param set_latest Point `latest.json` at this build.
#' @return `md_publish_tranches()`: the build directory, invisibly.
#' @examples
#' \dontrun{
#' # maintainer: write the tranches from a built database
#' md_publish_tranches()
#'
#' # user: download what one spec needs, and compile it
#' sp <- md_spec(layers = "bmf_active", names = c("legal", "dba"))
#' md_fetch_tranches(sp)
#' con <- md_tranche_db()
#' r <- md_compile(sp, con)
#' md_db_close(con)
#' }
#' @export
md_publish_tranches <- function(con = NULL, root = md_path("tranches"), tables = NULL,
                                commit = NA_character_, set_latest = TRUE) {
  own <- is.null(con)
  if (own) { con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE) }
  live <- DBI::dbListTables(con)
  # compile runs without the statistics and cluster tables, so only these are required
  miss <- setdiff(c("entity", "source_vintage", names(.md_tranche_split)), live)
  if (length(miss)) stop("the database has no ", paste(miss, collapse = ", "), call. = FALSE)
  # the normalizer the derived columns came from, checked as compile checks it
  stamp <- .md_compile_stamp(con, list(spec_hash = NA_character_))
  if (is.null(tables)) {
    tables <- live[!live %in% .md_tranche_skip &
                   !grepl("^(rollup_|cp_|frame_t|tr_)|_legacy$", live)]
  }
  tables <- union(tables, intersect(c(.md_tranche_compile_tables, names(.md_tranche_split)), live))

  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  tmp <- file.path(root, sprintf(".building-%d", Sys.getpid()))
  unlink(tmp, recursive = TRUE)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  rec <- list()
  put <- function(sql, path, table, layer = NA_character_, cls = NA_character_) {
    f <- file.path(tmp, path)
    dir.create(dirname(f), recursive = TRUE, showWarnings = FALSE)
    n <- DBI::dbExecute(con, sprintf("COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
                                     sql, gsub("\\\\", "/", f)))
    rec[[length(rec) + 1L]] <<- list(path = path, table = table, layer = layer,
                                     variant_class = cls, rows = as.numeric(n),
                                     bytes = file.size(f), md5 = unname(tools::md5sum(f)))
  }
  t0 <- Sys.time()

  # name and address, one file per layer and class; their derived columns the same way
  for (base in c("name", "address")) {
    id <- paste0(base, "_id")
    from <- sprintf("FROM %s b LEFT JOIN entity e ON e.ein = b.ein", base)
    lay <- "coalesce(e.layer, 'none')"; cls <- "coalesce(b.variant_class, 'none')"
    parts <- DBI::dbGetQuery(con, sprintf("SELECT DISTINCT %s AS layer, %s AS cls %s ORDER BY 1, 2",
                                          lay, cls, from))
    for (i in seq_len(nrow(parts))) {
      where <- sprintf("WHERE %s = '%s' AND %s = '%s'", lay, parts$layer[i], cls, parts$cls[i])
      leaf <- sprintf("%s/%s.parquet", parts$layer[i], parts$cls[i])
      put(sprintf("SELECT b.* %s %s ORDER BY b.ein, b.%s", from, where, id),
          paste0(base, "/", leaf), base, parts$layer[i], parts$cls[i])
      put(sprintf("SELECT d.* %s JOIN %s_derived d ON CAST(d.%s AS BIGINT) = b.%s %s
                   ORDER BY b.ein, b.%s", from, base, id, id, where, id),
          paste0(base, "_derived/", leaf), paste0(base, "_derived"),
          parts$layer[i], parts$cls[i])
    }
  }
  # every other table, whole; by EIN where it has one, so a lookup reads few row
  # groups, then by every other column, so the same table always writes the same
  # bytes and an unchanged file keeps its md5 from one build to the next
  for (t in setdiff(tables, names(.md_tranche_split))) {
    cols <- DBI::dbListFields(con, t)
    first <- intersect(if (t == "entity") c("layer", "ein") else "ein", cols)
    ord <- paste(sprintf('"%s"', c(first, setdiff(cols, first))), collapse = ", ")
    put(sprintf('SELECT * FROM "%s" ORDER BY %s', t, ord), sprintf("tables/%s.parquet", t), t)
  }

  files <- do.call(rbind, lapply(rec, as.data.frame, stringsAsFactors = FALSE))
  build <- paste0(format(Sys.Date()), "-",
                  substr(.md_md5_string(paste(files$path, files$md5, collapse = "\n")), 1, 8))
  man <- list(format = "matchdb-tranches/1", build = build,
              built = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
              matchdb_commit = commit, matchdb_version = stamp$matchdb_version,
              npnormalize_version = stamp$npnormalize_version,
              npmatch_version = stamp$npmatch_version,
              normalize_signature = stamp$normalize_signature,
              db_fingerprint = stamp$db_fingerprint,
              rows = sum(files$rows), bytes = sum(files$bytes), files = files)
  jsonlite::write_json(man, file.path(tmp, "manifest.json"), auto_unbox = TRUE, pretty = TRUE,
                       digits = NA, na = "null", dataframe = "rows")
  dir <- file.path(root, build)
  unlink(dir, recursive = TRUE)
  if (!file.rename(tmp, dir)) stop("could not move the build into ", dir, call. = FALSE)
  if (set_latest) md_tranche_pointer(build, root)
  .md_log("publish_tranches", build = build, note = paste("->", dir),
          elapsed = as.numeric(difftime(Sys.time(), t0, units = "secs")),
          files = data.frame(path = files$path, table = files$table, layer = files$layer,
                             variant_class = files$variant_class, status = "written",
                             rows = files$rows, bytes = files$bytes, md5 = files$md5,
                             stringsAsFactors = FALSE))
  message(sprintf("published tranches %s: %d files, %.2f GB, %.1f min -> %s", build,
                  nrow(files), sum(files$bytes) / 1e9,
                  as.numeric(difftime(Sys.time(), t0, units = "mins")), dir))
  invisible(dir)
}

#' @rdname md_publish_tranches
#' @param build A build id, e.g. `"2026-10-27-1a2b3c4d"`. By default the one
#'   `latest.json` names.
#' @export
md_tranche_pointer <- function(build, root = md_path("tranches")) {
  if (!file.exists(file.path(root, build, "manifest.json"))) {
    stop("no tranche build ", build, " under ", root, call. = FALSE)
  }
  jsonlite::write_json(list(build = build, set = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
                       file.path(root, "latest.json"), auto_unbox = TRUE, pretty = TRUE)
  invisible(build)
}

#' @rdname md_publish_tranches
#' @param spec An [md_spec()]: fetch the files [md_compile()] needs for it.
#' @param remote The base URL of a matchdb copy; tranches are under
#'   `<remote>/tranches/`.
#' @param overwrite Download again even when a file is already here and intact.
#' @details `md_fetch_tranches()` takes a `spec`, a set of `tables`, or both.
#'   `tables` names whole tables (`"orgtext"`, `"ein_relation"`, ...); naming
#'   `"name"` or `"address"` takes every partition with its derived columns, and
#'   `"all"` takes everything. With neither, it takes everything. `entity` and
#'   `source_vintage` always come along. Files already here and intact are
#'   not downloaded again, so fetching for a second spec adds only what the
#'   first did not need.
#' @return `md_fetch_tranches()`: the local build directory, invisibly.
#' @export
md_fetch_tranches <- function(spec = NULL, tables = NULL, build = NULL, remote = md_remote(),
                              root = md_path("tranches"), overwrite = FALSE) {
  t0 <- Sys.time()
  base <- paste0(sub("/+$", "", remote), "/tranches")
  if (is.null(build)) build <- jsonlite::fromJSON(.md_download_text(paste0(base, "/latest.json")))$build
  man_txt <- .md_download_text(sprintf("%s/%s/manifest.json", base, build))
  man <- .md_tranche_parse(man_txt)
  .md_tranche_sig_check(man)
  files <- man$files[.md_tranche_select(man$files, spec, tables), ]
  dir <- file.path(root, build)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  # the manifest first: it is the record of what this build is, kept even if
  # its parquet files are later pruned
  writeLines(man_txt, file.path(dir, "manifest.json"), useBytes = TRUE)
  prior <- if (file.exists(file.path(root, "latest.json")))
    jsonlite::read_json(file.path(root, "latest.json"))$build else NA
  status <- rep(NA_character_, nrow(files)); err <- rep("", nrow(files))
  record <- function() {
    note <- paste0(if (is.null(spec)) "" else paste("spec", spec$spec_hash),
                   if (is.null(tables)) "" else paste(" tables", paste(tables, collapse = " ")))
    det <- rbind(data.frame(path = "manifest.json", table = NA, layer = NA, variant_class = NA,
                            source = sprintf("%s/%s/manifest.json", base, build),
                            status = "manifest", rows = NA, bytes = nchar(man_txt, "bytes"),
                            md5 = .md_md5_string(man_txt), error = "", stringsAsFactors = FALSE),
                 data.frame(path = files$path, table = files$table, layer = files$layer,
                            variant_class = files$variant_class,
                            source = sprintf("%s/%s/%s", base, build, files$path),
                            status = ifelse(is.na(status), "not_reached", status),
                            rows = files$rows, bytes = files$bytes, md5 = files$md5, error = err,
                            stringsAsFactors = FALSE))
    # the manifest's own row (its md5 and source) is the provenance record of the run
    .md_log("fetch_tranches", build = build, spec_hash = spec$spec_hash %||% NA, files = det,
            note = trimws(note), elapsed = as.numeric(difftime(Sys.time(), t0, units = "secs")))
  }
  for (i in seq_len(nrow(files))) {
    dest <- file.path(dir, files$path[i])
    if (!overwrite && .md_tranche_intact(dest, files$bytes[i], files$md5[i])) {
      status[i] <- "reused"; next
    }
    dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
    # an identical file in an older build here: copy it rather than download it again
    src <- if (overwrite) NULL else .md_tranche_find_copy(root, files$md5[i], files$bytes[i], build)
    if (!is.null(src) && file.copy(src, dest, overwrite = TRUE) &&
        .md_tranche_intact(dest, files$bytes[i], files$md5[i])) {
      status[i] <- "copied"; next
    }
    message(sprintf("fetching %s (%.1f MB)", files$path[i], files$bytes[i] / 1e6))
    ok <- tryCatch({
      .md_download(sprintf("%s/%s/%s", base, build, files$path[i]), dest, md5 = files$md5[i])
      TRUE
    }, error = function(e) { err[i] <<- conditionMessage(e); FALSE })
    status[i] <- if (ok) "downloaded" else "failed"
    if (!ok) { record(); stop(err[i], call. = FALSE) }
  }
  md_tranche_pointer(build, root)
  if (!is.na(prior) && !identical(prior, build) && isTRUE(getOption("matchdb.log", TRUE))) {
    .md_tranche_log_change(prior, build, root)
  }
  record()
  message(sprintf("tranches %s: %d files here (%d already were, %d copied from an older build), %.2f GB downloaded",
                  build, nrow(files), sum(status == "reused"), sum(status == "copied"),
                  sum(files$bytes[status == "downloaded"]) / 1e9))
  invisible(dir)
}

# A version_change row saying what moved between two local tranche builds.
.md_tranche_log_change <- function(old, new, root) {
  tryCatch({
    d <- md_tranche_diff(old, new, root = root)
    o <- attr(d, "old"); n <- attr(d, "new")
    s <- table(factor(d$status, c("same", "changed", "added", "removed")))
    rc <- sum(d$rows_new[d$table %in% c("name", "address", "entity")], na.rm = TRUE) -
      sum(d$rows_old[d$table %in% c("name", "address", "entity")], na.rm = TRUE)
    note <- sprintf("tranches %s -> %s: files %s; name+address+entity rows %+d%s", old, new,
                    paste(names(s), s, collapse = " "), as.integer(rc),
                    if (identical(o$normalize_signature, n$normalize_signature)) "" else
                      sprintf("; normalizer %s -> %s", o$normalize_signature, n$normalize_signature))
    .md_log_version_row(note, build = new)
  }, error = function(e) .md_log_version_row(sprintf("tranches %s -> %s", old, new), build = new))
}

#' @rdname md_publish_tranches
#' @param verify Check every local file against its md5 before opening it.
#' @details `md_tranche_db()` opens an in-memory DuckDB holding one view per
#'   table, over whichever files are here. A spec whose files are not all here
#'   is an error from [md_compile()] naming them, never a reference built from
#'   part of the data. Close it with [md_db_close()].
#' @return `md_tranche_db()`: a DBI connection.
#' @export
md_tranche_db <- function(build = NULL, root = md_path("tranches"), verify = TRUE) {
  if (is.null(build)) {
    f <- file.path(root, "latest.json")
    if (!file.exists(f)) stop("no tranches under ", root, "; run md_fetch_tranches()", call. = FALSE)
    build <- jsonlite::read_json(f)$build
  }
  dir <- file.path(root, build)
  man <- .md_tranche_parse(paste(readLines(file.path(dir, "manifest.json"), warn = FALSE,
                                           encoding = "UTF-8"), collapse = "\n"))
  .md_tranche_sig_check(man)
  files <- man$files
  path <- file.path(dir, files$path)
  files$present <- file.exists(path)
  if (verify) {
    for (i in which(files$present)) {
      if (!.md_tranche_intact(path[i], files$bytes[i], files$md5[i])) {
        stop(sprintf("%s does not match its recorded md5; fetch it again with overwrite = TRUE",
                     files$path[i]), call. = FALSE)
      }
    }
  }
  con <- DBI::dbConnect(duckdb::duckdb())
  for (t in unique(files$table[files$present])) {
    p <- gsub("\\\\", "/", path[files$present & files$table == t])
    DBI::dbExecute(con, sprintf('CREATE VIEW "%s" AS SELECT * FROM read_parquet([%s])', t,
                                paste0("'", gsub("'", "''", p), "'", collapse = ", ")))
  }
  files$build <- build
  DBI::dbWriteTable(con, "md_tranche_files",
                    files[, c("build", "path", "table", "layer", "variant_class", "present")],
                    temporary = TRUE)
  con
}

# the tables md_compile() reads besides the four split ones
.md_tranche_compile_tables <- c("entity", "source_vintage", "stat_cell", "stat_name_cell",
                                "stat_token_cell", "cluster", "cluster_member")
# split tables, and the table whose partitions each follows
.md_tranche_split <- c(name = "name", name_derived = "name",
                       address = "address", address_derived = "address")
# the observation ledger: maintainer code only (dev/IDENTITY.md)
.md_tranche_skip <- c("obs", "release", "name_text", "address_text", "name_text_derived",
                      "address_text_derived")

.md_tranche_parse <- function(txt) {
  man <- jsonlite::fromJSON(txt, simplifyVector = TRUE)
  if (!identical(man$format, "matchdb-tranches/1")) {
    stop("not a matchdb tranche manifest this version reads: ", man$format %||% "(none)",
         call. = FALSE)
  }
  man
}

.md_tranche_sig_check <- function(man) {
  sig <- npnormalize::np_normalize_signature()
  if (!identical(man$normalize_signature, sig)) {
    stop(sprintf("tranches %s were built by normalizer %s; the installed one is %s. Their derived columns would be wrong for this normalizer.",
                 man$build, man$normalize_signature, sig), call. = FALSE)
  }
}

.md_tranche_intact <- function(path, bytes, md5) {
  file.exists(path) && isTRUE(file.size(path) == bytes) &&
    identical(unname(tools::md5sum(path)), md5)
}

# The files md_compile() reads for a spec (see "What a spec needs").
.md_tranche_need <- function(files, spec) {
  lay <- files$layer %in% spec$layers
  files$table %in% c(.md_tranche_compile_tables) |
    (files$table %in% c("name", "name_derived") & lay & files$variant_class != "in_care_of") |
    (files$table %in% c("address", "address_derived") & lay &
       files$variant_class %in% spec$addresses)
}

.md_tranche_select <- function(files, spec = NULL, tables = NULL) {
  if (is.null(spec) && is.null(tables)) return(rep(TRUE, nrow(files)))
  keep <- files$table %in% c("entity", "source_vintage")
  if (!is.null(spec)) {
    if (!inherits(spec, "md_spec")) stop("spec must come from md_spec()", call. = FALSE)
    keep <- keep | .md_tranche_need(files, spec)
  }
  if (!is.null(tables)) {
    if (identical(tables, "all")) return(rep(TRUE, nrow(files)))
    want <- union(tables, names(.md_tranche_split)[.md_tranche_split %in% tables])
    bad <- setdiff(tables, files$table)
    if (length(bad)) {
      stop(sprintf("no table %s in these tranches; there are: %s", paste(bad, collapse = ", "),
                   paste(sort(unique(files$table)), collapse = ", ")), call. = FALSE)
    }
    keep <- keep | files$table %in% want
  }
  keep
}

# A connection from md_tranche_db() holding only some files: refuse a spec
# whose files are not all here, rather than compile from part of the data.
.md_tranche_check <- function(con, spec) {
  if (!DBI::dbExistsTable(con, "md_tranche_files")) return(invisible())
  f <- DBI::dbReadTable(con, "md_tranche_files")
  miss <- f$path[.md_tranche_need(f, spec) & !f$present]
  if (length(miss)) {
    stop(sprintf("spec %s needs %d tranche file(s) not downloaded, e.g. %s. Run md_fetch_tranches(spec) first.",
                 spec$spec_hash, length(miss), paste(utils::head(miss, 3), collapse = ", ")),
         call. = FALSE)
  }
  invisible()
}
