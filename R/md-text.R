#' Text dictionaries and derived columns keyed on the text
#'
#' Phase 5 step 3 (`dev/IDENTITY.md` §4, §7). Every distinct name string and
#' every distinct address, as written, is stored once under its content-hash id
#' ([md_name_text_id()], [md_address_text_id()]), and the normalizer's output is
#' stored against that id and the normalizer signature:
#'
#' \describe{
#'   \item{`release`}{One row per file or partition read. Filled by the ingest
#'     engine (step 4); created here so the schema is complete.}
#'   \item{`name_text`}{`name_text_id`, `name_raw` (canonical form).}
#'   \item{`address_text`}{`address_text_id`, `street_raw`, `unit_raw`,
#'     `city_raw`, `state`, `zip5`, `zip_plus4`.}
#'   \item{`name_text_derived`}{Primary key `(name_text_id, normalize_signature)`:
#'     the same columns [md_build_derived()] stores in `name_derived`.}
#'   \item{`address_text_derived`}{Primary key `(address_text_id,
#'     normalize_signature)`: the columns of `address_derived`.}
#' }
#'
#' What this changes against `name_derived`/`address_derived`, which key on row
#' ids:
#' \itemize{
#'   \item A text id never changes, so a re-ingest cannot orphan a derived row.
#'   \item Only strings never seen before are normalized. A string shared by
#'     thousands of EINs is normalized once.
#'   \item Two normalizer signatures can sit side by side, so adopting a new
#'     npmatch never overwrites the columns a published tier was built on.
#' }
#'
#' Until the ingest engine exists (step 4), [md_build_text()] fills the
#' dictionaries from the current `name` and `address` tables, so the sizes and
#' timings the plan asks for can be measured on a built database.
#'
#' @param con A DuckDB connection, usually from [md_db()].
#' @name md_text
NULL

#' @rdname md_text
#' @return `md_text_schema()`: `con`, invisibly.
#' @export
md_text_schema <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS release (
      release_id VARCHAR PRIMARY KEY, source VARCHAR NOT NULL, kind VARCHAR,
      version VARCHAR NOT NULL, part VARCHAR, file_md5 VARCHAR,
      content_vintage VARCHAR, ingested_at TIMESTAMP)")
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS name_text (
      name_text_id VARCHAR PRIMARY KEY, name_raw VARCHAR NOT NULL)")
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS address_text (
      address_text_id VARCHAR PRIMARY KEY, street_raw VARCHAR, unit_raw VARCHAR,
      city_raw VARCHAR, state VARCHAR, zip5 VARCHAR, zip_plus4 VARCHAR)")
  invisible(con)
}

#' @rdname md_text
#' @param relation A table, view or query (in parentheses) holding raw text.
#'   Names: a `name_raw` column. Addresses: `street_raw`, `city_raw`, `state`,
#'   `zip5`, `zip_plus4`, and optionally `unit_raw`.
#' @param what `"name"` or `"address"`.
#' @return `md_add_text()`: the number of new strings, invisibly. Existing ids
#'   are left alone, so adding the same text twice adds nothing.
#' @export
md_add_text <- function(con, relation, what = c("name", "address")) {
  what <- match.arg(what)
  md_text_schema(con)
  md_identity_macros(con)
  if (what == "name") {
    # an empty name is not a name
    sql <- sprintf("
      INSERT INTO name_text
      SELECT DISTINCT md_name_text_id(name_raw), md_canon(name_raw)
      FROM %s r
      WHERE md_canon(r.name_raw) <> ''
        AND md_name_text_id(r.name_raw) NOT IN (SELECT name_text_id FROM name_text)",
      relation)
  } else {
    has_unit <- "unit_raw" %in% names(DBI::dbGetQuery(con,
      sprintf("SELECT * FROM %s LIMIT 0", relation)))
    unit <- if (has_unit) "r.unit_raw" else "CAST(NULL AS VARCHAR)"
    id <- sprintf("md_address_text_id(r.street_raw, %s, r.city_raw, r.state, r.zip5, r.zip_plus4)",
                  unit)
    # an address with every field empty says nothing
    sql <- sprintf("
      INSERT INTO address_text
      SELECT DISTINCT %s, md_canon(r.street_raw), md_canon(%s), md_canon(r.city_raw),
             md_canon(r.state), md_canon(r.zip5), md_canon(r.zip_plus4)
      FROM %s r
      WHERE md_canon(r.street_raw) || md_canon(%s) || md_canon(r.city_raw) ||
            md_canon(r.state) || md_canon(r.zip5) || md_canon(r.zip_plus4) <> ''
        AND %s NOT IN (SELECT address_text_id FROM address_text)",
      id, unit, relation, unit, id)
  }
  invisible(DBI::dbExecute(con, sql))
}

#' @rdname md_text
#' @return `md_build_text()`: new strings per table, invisibly.
#' @export
md_build_text <- function(con) {
  n <- c(name = md_add_text(con, "name", "name"),
         address = md_add_text(con, "address", "address"))
  message(sprintf("name_text: +%s (%s total); address_text: +%s (%s total)",
                  format(n[["name"]], big.mark = ","),
                  format(.md_n(con, "name_text"), big.mark = ","),
                  format(n[["address"]], big.mark = ","),
                  format(.md_n(con, "address_text"), big.mark = ",")))
  invisible(n)
}

#' @rdname md_text
#' @param chunk Strings per normalizer pass. Bounds memory, not correctness.
#' @return `md_build_text_derived()`: strings normalized per table, invisibly.
#' @export
md_build_text_derived <- function(con, what = c("name", "address"), chunk = 1000000L) {
  if (!requireNamespace("npmatch", quietly = TRUE)) stop("npmatch is required", call. = FALSE)
  md_text_schema(con)
  sig <- npmatch::np_normalize_signature()
  out <- integer(0)
  blank <- function(n) rep("", n)
  e <- function(x) ifelse(is.na(x), "", x)
  if ("name" %in% what) {
    out["name"] <- .md_text_derive_pass(con, "name_text", "name_text_id",
      "name_text_derived", .md_derived_name_cols, sig, chunk,
      select = "SELECT name_text_id AS id, name_raw FROM name_text",
      shape = function(d) data.frame(
        name = e(d$name_raw), dba = blank(nrow(d)), division = blank(nrow(d)),
        street = blank(nrow(d)), zip5 = blank(nrow(d)), zip_plus4 = blank(nrow(d)),
        state = blank(nrow(d)), stringsAsFactors = FALSE))
  }
  if ("address" %in% what) {
    # the same four inputs md_build_derived() gives the normalizer
    out["address"] <- .md_text_derive_pass(con, "address_text", "address_text_id",
      "address_text_derived", .md_derived_address_cols, sig, chunk,
      select = "SELECT address_text_id AS id, street_raw, zip5, zip_plus4, state FROM address_text",
      shape = function(d) data.frame(
        name = blank(nrow(d)), dba = blank(nrow(d)), division = blank(nrow(d)),
        street = e(d$street_raw), zip5 = e(d$zip5), zip_plus4 = e(d$zip_plus4),
        state = e(d$state), stringsAsFactors = FALSE))
  }
  invisible(out)
}

#' @rdname md_text
#' @param signature The normalizer signature to check against. Defaults to the
#'   installed npmatch's.
#' @param stop_on_missing Error, rather than return, when a string has no row
#'   for the signature.
#' @return `md_check_text_derived()`: a data frame per table of strings,
#'   strings with a row for the signature, and strings missing one.
#' @export
md_check_text_derived <- function(con, signature = npmatch::np_normalize_signature(),
                                  stop_on_missing = FALSE) {
  one <- function(src, id, dest) {
    n <- .md_n(con, src)
    have <- if (DBI::dbExistsTable(con, dest)) DBI::dbGetQuery(con, sprintf(
      "SELECT count(*) AS n FROM %s WHERE normalize_signature = '%s'", dest, signature))$n else 0
    data.frame(table = dest, n_text = n, n_derived = have, n_missing = n - have)
  }
  out <- rbind(one("name_text", "name_text_id", "name_text_derived"),
               one("address_text", "address_text_id", "address_text_derived"))
  if (stop_on_missing && any(out$n_missing > 0)) {
    stop(sprintf("%s string(s) have no derived row for normalizer %s. Run md_build_text_derived().",
                 format(sum(out$n_missing), big.mark = ","), signature), call. = FALSE)
  }
  out
}

#' @rdname md_text
#' @return `md_text_stats()`: the step 3 measurement - rows in `name` and
#'   `address` against distinct strings in the dictionaries, and the derived
#'   rows per signature.
#' @export
md_text_stats <- function(con) {
  n <- function(sql) DBI::dbGetQuery(con, sql)$n
  sizes <- data.frame(
    table = c("name", "address"),
    rows = c(.md_n(con, "name"), .md_n(con, "address")),
    distinct_text = c(.md_n(con, "name_text"), .md_n(con, "address_text")))
  sizes$rows_per_text <- round(sizes$rows / pmax(sizes$distinct_text, 1), 2)
  sigs <- do.call(rbind, lapply(c("name_text_derived", "address_text_derived"), function(t) {
    if (!DBI::dbExistsTable(con, t)) return(NULL)
    d <- DBI::dbGetQuery(con, sprintf(
      "SELECT normalize_signature, count(*) AS n FROM %s GROUP BY 1 ORDER BY 1", t))
    if (nrow(d)) cbind(table = t, d) else NULL
  }))
  list(sizes = sizes, signatures = sigs)
}

# Normalize the strings in `src` that have no row in `dest` for `sig`, and
# append them. The set to do is fixed in a temp table first: paging over "not
# yet derived" while appending would shrink the set under the offset.
.md_text_derive_pass <- function(con, src, id, dest, keep, sig, chunk, select, shape) {
  msg <- function(...) message(sprintf(...))
  if (!DBI::dbExistsTable(con, dest)) .md_text_derived_create(con, dest, id, keep, shape)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE txt_todo AS
    SELECT %s FROM %s
    WHERE %s NOT IN (SELECT %s FROM %s WHERE normalize_signature = '%s')",
    id, src, id, id, dest, sig))
  n <- .md_n(con, "txt_todo")
  msg("%s: %s new string(s) to normalize under %s", src, format(n, big.mark = ","), sig)
  if (n == 0) return(0L)
  t0 <- Sys.time(); done <- 0L
  for (off in seq(0, n - 1, by = chunk)) {
    d <- DBI::dbGetQuery(con, sprintf(
      "%s WHERE %s IN (SELECT %s FROM txt_todo ORDER BY %s LIMIT %d OFFSET %d) ORDER BY %s",
      select, id, id, id, chunk, off, id))
    if (!nrow(d)) break
    o <- npmatch::np_normalize(shape(d))
    res <- cbind(stats::setNames(data.frame(d$id, stringsAsFactors = FALSE), id),
                 normalize_signature = sig, o[, keep, drop = FALSE],
                 stringsAsFactors = FALSE)
    DBI::dbAppendTable(con, dest, res)
    done <- done + nrow(d)
  }
  msg("%s -> %s: %s string(s) in %.1f min", src, dest, format(done, big.mark = ","),
      as.numeric(difftime(Sys.time(), t0, units = "mins")))
  done
}

# Create a derived table with a real primary key. Column types are read off the
# normalizer's own output for a one-row input, so they follow npmatch rather
# than a list kept here.
.md_text_derived_create <- function(con, dest, id, keep, shape) {
  probe <- npmatch::np_normalize(shape(data.frame(
    id = "x", name_raw = "PROBE", street_raw = "1 MAIN ST", zip5 = "60601",
    zip_plus4 = "", state = "IL", stringsAsFactors = FALSE)))[, keep, drop = FALSE]
  sql_type <- function(v) {
    if (is.logical(v)) "BOOLEAN" else if (is.integer(v)) "INTEGER"
    else if (is.numeric(v)) "DOUBLE" else "VARCHAR"
  }
  cols <- vapply(names(probe), function(nm) sprintf('"%s" %s', nm, sql_type(probe[[nm]])),
                 character(1))
  DBI::dbExecute(con, sprintf(
    "CREATE TABLE %s (%s VARCHAR NOT NULL, normalize_signature VARCHAR NOT NULL, %s,
       PRIMARY KEY (%s, normalize_signature))",
    dest, id, paste(cols, collapse = ", "), id))
}
