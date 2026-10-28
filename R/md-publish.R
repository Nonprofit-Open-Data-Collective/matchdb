#' Publish a compiled reference, and read one back
#'
#' `md_publish()` compiles a spec and writes it as a bundle; `md_reference()`
#' reads a published bundle into the form npmatch matches against. This is
#' `PLAN.md` section 7b's first tier: most users download a compiled
#' reference, not the database.
#'
#' @section What a bundle is:
#' `<root>/<label>/<spec_hash>/` holds
#' \describe{
#'   \item{`reference.parquet`}{the frame [md_compile()] returns}
#'   \item{`name_freq.parquet`, `token_idf.parquet`}{npmatch's corpus
#'     statistics for exactly that frame}
#'   \item{`addr_freq.parquet`}{address sharing over exactly that frame
#'     ([md_addr_freq()]): records per address and suite, suite coverage, name
#'     concentration and npmatch's place class}
#'   \item{`place.parquet`, `place_layer.parquet`, `place_unit.parquet`}{when
#'     [md_build_places()] has run: the evidence and flags for the places the
#'     frame touches, counted over the whole database}
#'   \item{`report.json`}{the compile report: shape and absence}
#'   \item{`stamp.json`}{the spec, the spec hash, the database fingerprint, the
#'     normalizer signature, the npmatch and matchdb versions, and the md5 of
#'     every file above}
#' }
#' and `<root>/latest.json` maps each label to the bundle currently published
#' under it.
#'
#' @section Why the stamp is checked, and rollback is a pointer:
#' A bundle's derived columns and statistics are only right for the normalizer
#' that made them (section 9). `md_reference()` refuses a bundle whose
#' normalizer signature is not the installed one, and one whose files do not
#' match their recorded md5. Rolling back is editing `latest.json` back to an
#' earlier hash - [md_publish_pointer()] - since every bundle stays where it was
#' written (section 7d).
#'
#' @param spec An [md_spec()] with a `label`.
#' @param root The publish directory. Defaults to `md_data_root()/publish`.
#' @param con A connection from [md_db()].
#' @param set_latest Point `latest.json` at this bundle.
#' @return The bundle directory, invisibly.
#' @export
md_publish <- function(spec, root = md_path("publish"), con = NULL, set_latest = TRUE) {
  if (!inherits(spec, "md_spec") || is.null(spec$label)) {
    stop("md_publish() needs an md_spec() with a label", call. = FALSE)
  }
  own <- is.null(con)
  if (own) { con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE) }
  r <- md_compile(spec, con)
  dir <- file.path(root, spec$label, spec$spec_hash)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  files <- c(reference = "reference.parquet", name_freq = "name_freq.parquet",
             token_idf = "token_idf.parquet", report = "report.json")
  .md_write_parquet(as.data.frame(r$reference), file.path(dir, files[["reference"]]))
  .md_write_parquet(data.frame(name_key = names(r$name_freq), n = unname(r$name_freq),
                               stringsAsFactors = FALSE), file.path(dir, files[["name_freq"]]))
  .md_write_parquet(data.frame(token = names(r$token_idf), idf = unname(r$token_idf),
                               stringsAsFactors = FALSE), file.path(dir, files[["token_idf"]]))
  jsonlite::write_json(r$report, file.path(dir, files[["report"]]), auto_unbox = TRUE,
                       pretty = TRUE, digits = NA, na = "null")
  # Address sharing over exactly this frame's rows (dev/PLACES.md section 6), so a
  # run against a slice of the tier still reads the whole tier's counts.
  af <- md_addr_freq(as.data.frame(r$reference))
  files[["addr_freq"]] <- "addr_freq.parquet"
  .md_write_parquet(.md_addr_freq_table(af), file.path(dir, files[["addr_freq"]]))
  # The place evidence and flags (md_build_places()) for the places this frame
  # touches: what the tier's own counts cannot see - group rulings, mailbox
  # stores, care-of agents, churn, buildings.
  if (all(c("place", "place_layer", "place_unit") %in% DBI::dbListTables(con))) {
    keys <- unique(md_place_key(r$reference$street_key, r$reference$zip5))
    duckdb::duckdb_register(con, "pub_places", data.frame(place_key = keys[nzchar(keys)]))
    for (t in c("place", "place_layer", "place_unit")) {
      files[[t]] <- paste0(t, ".parquet")
      .md_write_parquet(DBI::dbGetQuery(con, sprintf(
        "SELECT t.* FROM %s t JOIN pub_places USING (place_key) ORDER BY ALL", t)),
        file.path(dir, files[[t]]))
    }
    duckdb::duckdb_unregister(con, "pub_places")
  }
  # The clusters holding the bundle's EINs, members limited to those EINs: what
  # npmatch's np_cluster_rollup() and np_pair_links() read.
  if (all(c("cluster", "cluster_member") %in% DBI::dbListTables(con))) {
    duckdb::duckdb_register(con, "pub_eins", data.frame(ein = unique(r$reference$.ein)))
    opt <- c(m.role = "role" %in% DBI::dbListFields(con, "cluster_member"),
             c.size = "size" %in% DBI::dbListFields(con, "cluster"),
             c.brand_tokens = "brand_tokens" %in% DBI::dbListFields(con, "cluster"))
    cl <- DBI::dbGetQuery(con, sprintf("
      SELECT m.cluster_id, c.cluster_type, m.ein %s
      FROM cluster_member m JOIN pub_eins USING (ein) JOIN cluster c USING (cluster_id)
      ORDER BY m.cluster_id, m.ein",
      paste0(", ", names(opt)[opt], collapse = "")))
    duckdb::duckdb_unregister(con, "pub_eins")
    files[["clusters"]] <- "clusters.parquet"
    .md_write_parquet(cl, file.path(dir, files[["clusters"]]))
  }

  stamp <- c(r$stamp, list(
    label = spec$label,
    spec = unclass(spec[setdiff(names(spec), c("label", "spec_hash"))]),
    addr_freq = list(share_min = af$share_min, unit_coverage_min = af$unit_coverage_min),
    rows = nrow(r$reference),
    files = as.list(stats::setNames(unname(tools::md5sum(file.path(dir, files))), files))))
  jsonlite::write_json(stamp, file.path(dir, "stamp.json"), auto_unbox = TRUE, pretty = TRUE,
                       digits = NA, na = "null", null = "null")
  if (set_latest) md_publish_pointer(spec$label, spec$spec_hash, root)
  .md_log("publish", spec_hash = spec$spec_hash,
          note = sprintf("label %s; %s rows -> %s", spec$label,
                         format(nrow(r$reference), big.mark = ","), dir),
          files = data.frame(path = c(unname(files), "stamp.json"), status = "written",
                             bytes = file.size(file.path(dir, c(files, "stamp.json"))),
                             md5 = unname(tools::md5sum(file.path(dir, c(files, "stamp.json")))),
                             stringsAsFactors = FALSE))
  message(sprintf("published %s %s: %s rows -> %s", spec$label, spec$spec_hash,
                  format(nrow(r$reference), big.mark = ","), dir))
  invisible(dir)
}

#' @rdname md_publish
#' @param label A published label, e.g. `"active-observed"`.
#' @param spec_hash The bundle to point the label at.
#' @export
md_publish_pointer <- function(label, spec_hash, root = md_path("publish")) {
  if (!file.exists(file.path(root, label, spec_hash, "stamp.json"))) {
    stop("no published bundle ", label, "/", spec_hash, " under ", root, call. = FALSE)
  }
  f <- file.path(root, "latest.json")
  latest <- if (file.exists(f)) jsonlite::read_json(f) else list()
  latest[[label]] <- list(spec_hash = spec_hash,
                          set = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))
  jsonlite::write_json(latest, f, auto_unbox = TRUE, pretty = TRUE)
  invisible(latest)
}

#' @rdname md_publish
#' @param build_index Also build npmatch's blocking index ([npmatch::np_ref_index()]),
#'   so the result can go straight to the cascade. Needs npmatch, which matchdb
#'   only suggests; without it the index is skipped with a message.
#' @param fetch Download the bundle first with [md_fetch_reference()]: `TRUE`
#'   always (a bundle already here and intact is not downloaded again),
#'   `"missing"` only when the label is not published locally.
#' @return For `md_reference()`, a list: `reference` (an `np_reference`),
#'   `name_freq`, `token_idf`, `addr_freq` (an `np_addr_freq`, when published),
#'   `places` (a list of the `place`, `place_layer` and `place_unit` rows for
#'   the bundle's places, when published), `clusters` (when published),
#'   `ref_index` (when built) and `stamp`.
#' @export
md_reference <- function(label, root = md_path("publish"), spec_hash = NULL,
                         build_index = TRUE, fetch = FALSE) {
  local_has <- function() {
    f <- file.path(root, "latest.json")
    if (!is.null(spec_hash)) return(file.exists(file.path(root, label, spec_hash, "stamp.json")))
    file.exists(f) && !is.null(jsonlite::read_json(f)[[label]])
  }
  if (isTRUE(fetch) || (identical(fetch, "missing") && !local_has())) {
    md_fetch_reference(label, spec_hash = spec_hash, root = root)
  }
  if (is.null(spec_hash)) {
    f <- file.path(root, "latest.json")
    if (!file.exists(f)) stop("no latest.json under ", root, call. = FALSE)
    latest <- jsonlite::read_json(f)
    if (is.null(latest[[label]])) stop("nothing published as ", label, call. = FALSE)
    spec_hash <- latest[[label]]$spec_hash
  }
  dir <- file.path(root, label, spec_hash)
  stamp <- jsonlite::read_json(file.path(dir, "stamp.json"))
  sig <- npnormalize::np_normalize_signature()
  if (!identical(stamp$normalize_signature, sig)) {
    stop(sprintf("bundle %s/%s was built by normalizer %s; the installed one is %s. Its derived columns and statistics would be wrong for this normalizer - republish it.",
                 label, spec_hash, stamp$normalize_signature, sig), call. = FALSE)
  }
  for (fn in names(stamp$files)) {
    got <- unname(tools::md5sum(file.path(dir, fn)))
    if (!identical(got, stamp$files[[fn]])) {
      stop(sprintf("%s in bundle %s/%s does not match its recorded md5", fn, label,
                   spec_hash), call. = FALSE)
    }
  }
  ref <- .md_read_parquet(file.path(dir, "reference.parquet"))
  class(ref) <- c("np_reference", "data.frame")
  nf <- .md_read_parquet(file.path(dir, "name_freq.parquet"))
  ti <- .md_read_parquet(file.path(dir, "token_idf.parquet"))
  out <- list(reference = ref,
              name_freq = stats::setNames(as.integer(nf$n), nf$name_key),
              token_idf = stats::setNames(as.numeric(ti$idf), ti$token),
              stamp = stamp)
  if (file.exists(file.path(dir, "clusters.parquet"))) {
    out$clusters <- .md_read_parquet(file.path(dir, "clusters.parquet"))
  }
  # the np_addr_freq object np_compare(addr_freq = ) takes; absent in bundles
  # published before dev/PLACES.md
  if (file.exists(file.path(dir, "addr_freq.parquet"))) {
    p <- stamp$addr_freq
    out$addr_freq <- .md_addr_freq_from_table(.md_read_parquet(file.path(dir, "addr_freq.parquet")),
                                              p$share_min %||% 10L, p$unit_coverage_min %||% 0.5)
  }
  if (file.exists(file.path(dir, "place.parquet"))) {
    out$places <- lapply(c(place = "place", layer = "place_layer", unit = "place_unit"),
                         function(t) .md_read_parquet(file.path(dir, paste0(t, ".parquet"))))
  }
  if (build_index) {
    if (requireNamespace("npmatch", quietly = TRUE)) {
      out$ref_index <- npmatch::np_ref_index(ref)
    } else {
      message("npmatch is not installed, so the blocking index was not built; ",
              "npmatch builds it itself when given none.")
    }
  }
  out
}

# Parquet through DuckDB, so publishing needs no arrow dependency.
.md_write_parquet <- function(df, path) {
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  duckdb::duckdb_register(con, "pq_out", df)
  DBI::dbExecute(con, sprintf("COPY pq_out TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
                              gsub("\\\\", "/", path)))
  invisible(path)
}
.md_read_parquet <- function(path) {
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", gsub("\\\\", "/", path)))
}
