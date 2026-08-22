#' Open the matchdb database
#'
#' `MATCHDB.duckdb` under `db/` in the data root is the relational source of
#' truth (§7b tier 3). It is the ingest target and the thing publish reads from;
#' it is not the consumption path for matching.
#'
#' @param read_only Open read-only. Use for provenance queries.
#' @param path Override the database location.
#' @return A DBI connection. Close with [md_db_close()].
#' @export
md_db <- function(read_only = FALSE, path = NULL) {
  if (!requireNamespace("duckdb", quietly = TRUE)) {
    stop("duckdb is required to open the database", call. = FALSE)
  }
  if (is.null(path)) {
    md_path("db", create = TRUE)
    path <- md_path("db", "MATCHDB.duckdb")
  }
  DBI::dbConnect(duckdb::duckdb(), dbdir = path, read_only = read_only)
}

#' @rdname md_db
#' @param con A connection from [md_db()].
#' @export
md_db_close <- function(con) {
  DBI::dbDisconnect(con, shutdown = TRUE)
}

#' Record an ingest in the audit table
#'
#' Writes one `source_vintage` row per load, carrying the pin (§4). Nothing else
#' makes a compiled reference explainable six months later.
#'
#' @param con A connection from [md_db()].
#' @param source,version The pinned source.
#' @param table_name,row_count What was written.
#' @param build_note Free text.
#' @export
md_record_vintage <- function(con, source, version, table_name, row_count,
                              build_note = "") {
  pin <- md_source_read_pin(source, version)
  if (is.null(pin)) {
    stop("no pin for ", source, "/", version,
         " - a source must be pinned before it can be ingested", call. = FALSE)
  }
  row <- data.frame(
    vintage_id        = paste0(source, "-", version, ":", table_name),
    source            = source,
    version           = version,
    table_name        = table_name,
    url               = pin$url %||% NA_character_,
    fetched           = pin$fetched %||% NA_character_,
    upstream_etag     = pin$upstream_etag %||% NA_character_,
    upstream_modified = pin$upstream_modified %||% NA_character_,
    local_md5         = pin$local_md5 %||% NA_character_,
    row_count         = as.integer(row_count),
    build_note        = build_note,
    npmatch_version   = pin$npmatch_version %||% NA_character_,
    normalize_signature = pin$normalize_signature %||% NA_character_,
    stringsAsFactors  = FALSE
  )
  if (!DBI::dbExistsTable(con, "source_vintage")) {
    DBI::dbWriteTable(con, "source_vintage", row)
  } else {
    DBI::dbExecute(con, "DELETE FROM source_vintage WHERE vintage_id = ?",
                   params = list(row$vintage_id))
    DBI::dbAppendTable(con, "source_vintage", row)
  }
  invisible(row)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L || is.na(a[1])) b else a
