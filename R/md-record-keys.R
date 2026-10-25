#' The natural key of each source
#'
#' What identifies one record in each source, so an observation's id
#' (`dev/IDENTITY.md` §3) can be computed from the raw file and stays the same
#' across re-releases. Phase 5 step 2.
#'
#' Columns:
#' \describe{
#'   \item{`source`, `kind`}{As in [md_sources()].}
#'   \item{`filing_key`}{The column(s) naming one filing or one record:
#'     `OBJECTID` for e-file tables, `FORM_ID_NUMBER` for Form 8871, the EIN for
#'     one-row-per-EIN files.}
#'   \item{`grain`}{`record`: `filing_key` alone is unique. `row`: a filing has
#'     many rows (one per grant, related organisation, officer), so a row is
#'     identified by `filing_key` plus a hash of its fields plus an occurrence
#'     counter among identical rows. Identical rows inside one return are real -
#'     the 2022 Schedule I sample has 11 in 4,646 - and the counter keeps them
#'     apart.}
#'   \item{`trace_key`}{A publisher's row identifier stored with each
#'     observation for tracing by hand, but **not** hashed into its id:
#'     e-file `TABLE_ID` is the row's position in the return, and a parser
#'     change could renumber it, while the row's content cannot change.}
#'   \item{`period`}{The column giving the observation's year, if any.}
#'   \item{`asserted_by`}{For a third-party source, the column naming who wrote
#'     the row (the filer).}
#'   \item{`latest_by`}{For sources with amended returns: count only the filing
#'     with the greatest value of this column per (filer, period) - the latest
#'     return (`dev/IDENTITY.md` §9, decided 2026-10-24).}
#'   \item{`evidence`}{How the key was confirmed.}
#' }
#'
#' Confirmed on the first 2 MB of each 2022 e-file table and of the 2026-07
#' e-Postcard and revocation files, downloaded 2026-10-24. A sample can show a
#' key is *not* unique but cannot prove it is, so [md_check_record_key()] runs
#' the same test on a whole file at ingest.
#'
#' @return A data frame, one row per source in [md_sources()].
#' @export
md_record_keys <- function() {
  ef_row <- function(source, n, k) c(source, "OBJECTID", "row", "TABLE_ID", "TAX_YEAR",
    "EIN2", "RETURN_TIME_STAMP",
    sprintf("2022 sample: OBJECTID + TABLE_ID unique over %s rows, %s filings", n, k))
  rows <- list(
    c("bmf_unified", "EIN2", "record", NA, NA, NA, NA,
      "documented: one row per EIN (3,698,124 rows, 3,698,124 EINs)"),
    c("bmf_active", "ein", "record", NA, NA, NA, NA, "2026-01 sample: ein unique over 2,559 rows"),
    c("e_postcard", "ein", "record", "ID", "tax_year", NA, NA,
      "2026-07 sample: ein and ID each unique over 8,232 rows"),
    c("efile_header", "OBJECTID", "record", NA, "TAX_YEAR", NA, "RETURN_TIME_STAMP",
      "2022 sample: OBJECTID unique over 3,267 rows; 50 EIN-years have two filings"),
    c("efile_orgtext", "OBJECTID", "record", NA, "TAX_YEAR", NA, "RETURN_TIME_STAMP",
      "2022 sample: OBJECTID unique over 4,703 rows"),
    ef_row("efile_officers", "5,815", "370"),
    c("f1023ez", "EIN", "record", NA, "year of approval", NA, NA,
      "not sampled (xlsx cannot be range-read); EIN assumed"),
    c("irs527", "FORM_ID_NUMBER", "record", NA, NA, NA, NA,
      "2024-11 sample: FORM_ID_NUMBER unique over 4,314 rows; EINs repeat (amendments)"),
    c("revocations", "ein, revocation_date", "record", "ID", "revocation_date", NA, NA,
      "2026-07 sample: unique over 11,138 rows, 247 of them reinstated; full file has repeat EINs"),
    ef_row("schedi", "4,646", "178"),
    ef_row("efile_related", "4,684", "713"),
    ef_row("efile_disregarded", "4,825", "1,619"),
    ef_row("efile_related_ptr", "4,825", "351"),
    ef_row("efile_related_corp", "5,109", "592"),
    ef_row("efile_affiliate_listing", "3,860", "158"),
    ef_row("efile_sched_c_affil", "2,364", "225"),
    c("irs527_related", "ENTITY_ID", "record", NA, NA, "EIN", NA,
      "2024-11 sample: ENTITY_ID unique over 11,099 rows"),
    c("meta_names", "EIN2", "record", NA, NA, NA, NA, "sample: EIN2 unique over 16,191 rows"),
    c("meta_addresses", "EIN2", "record", NA, NA, NA, NA, "sample: EIN2 unique over 10,799 rows"),
    c("meta_group_aff", "EIN", "record", NA, NA, NA, NA, "sample: EIN unique over 81,496 rows"),
    c("meta_group_number", "EIN", "record", NA, NA, NA, NA, "sample: EIN unique over 86,932 rows"),
    c("meta_group_return", "EIN", "record", NA, NA, NA, NA, "sample: EIN unique over 37,416 rows"),
    c("ntee_crosswalk", "EIN2", "record", NA, NA, NA, NA, "local file, not sampled: EIN2 assumed"),
    c("address_crosswalk", "EIN2", "row", NA, NA, NA, NA,
      "local file, not sampled: one row per (EIN, address spell), so EIN2 + row hash"),
    c("address_geocoded", "EIN2", "record", NA, NA, NA, NA, "local file, not sampled: EIN2 assumed")
  )
  out <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(out) <- c("source", "filing_key", "grain", "trace_key", "period", "asserted_by",
                  "latest_by", "evidence")
  kinds <- md_sources()[, c("source", "kind")]
  out <- merge(kinds, out, by = "source", all.x = TRUE, sort = FALSE)
  out[match(kinds$source, out$source), , drop = FALSE]
}

#' Check a source's natural key on a loaded file
#'
#' The Phase 5 step 2 check, run on a whole file rather than a sample: is the
#' key in [md_record_keys()] unique? For a `record` source the filing key must
#' be unique. For a `row` source, rows repeating the same filing key **and** the
#' same content are counted as repeats: they are legitimate (two identical
#' grants), and the occurrence counter is what tells them apart, but the count
#' is reported so a jump in it is visible.
#'
#' @param con A DuckDB connection.
#' @param relation A table, view or `read_csv(...)` expression holding the raw
#'   file, with the source's own column names.
#' @param source A source from [md_record_keys()].
#' @return A one-row data frame: `source`, `grain`, `n_rows`, `n_keys`,
#'   `n_repeats`, `ok`. `ok` is `FALSE` only for a `record` source whose key
#'   repeats.
#' @export
md_check_record_key <- function(con, relation, source) {
  k <- md_record_keys()
  k <- k[k$source == source, , drop = FALSE]
  if (!nrow(k)) stop("unknown source: ", source, call. = FALSE)
  cols <- names(DBI::dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", relation)))
  key <- trimws(strsplit(k$filing_key, ",")[[1]])
  missing <- setdiff(key, cols)
  if (length(missing)) {
    stop(source, ": key column(s) not in the file: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }
  q <- function(x) paste0('"', x, '"', collapse = ", ")
  if (k$grain == "record") {
    r <- DBI::dbGetQuery(con, sprintf(
      "SELECT count(*) AS n_rows, count(DISTINCT (%s)) AS n_keys FROM %s", q(key), relation))
    n_repeats <- r$n_rows - r$n_keys
    ok <- n_repeats == 0
  } else {
    # content = every column except the publisher's row position
    content <- setdiff(cols, k$trace_key)
    r <- DBI::dbGetQuery(con, sprintf(
      "SELECT count(*) AS n_rows, count(DISTINCT (%s)) AS n_keys FROM %s",
      q(content), relation))
    n_repeats <- r$n_rows - r$n_keys
    ok <- TRUE
  }
  data.frame(source = source, grain = k$grain, n_rows = r$n_rows, n_keys = r$n_keys,
             n_repeats = n_repeats, ok = ok, stringsAsFactors = FALSE)
}
