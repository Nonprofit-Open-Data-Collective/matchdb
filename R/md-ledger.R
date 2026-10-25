#' The observation ledger
#'
#' Phase 5 step 4 (`dev/IDENTITY.md` §4, §5). Every observation of a name or
#' address, from every release of every source, is one row of `obs`. Rows are
#' never deleted: a row a later release no longer carries is marked
#' `retracted_in`, and a snapshot value that stops appearing simply stops being
#' extended.
#'
#' \preformatted{
#' obs_id           content-hash id (below)
#' source, kind     as in md_sources()
#' part             the partition (tax year) the row came from, or NULL
#' ein              EIN2
#' role             legal | dba | in_care_of | observed | mailing | historical | ...
#' name_text_id     NULL for an address-only record
#' address_text_id  NULL for a name-only record
#' asserted_by      the filer who wrote it, for third-party sources
#' record_key       the source's natural key (md_record_keys())
#' trace_key        a publisher's row id (e-file TABLE_ID), for tracing only
#' period           the year the row describes, if it has one
#' filed_at         the return's timestamp, so the latest return can be chosen
#' first_seen, last_seen  release vintages, or the range the source states
#' bounds_kind      spell | period | stated | envelope
#' first_release, last_release  release_ids
#' retracted_in     release_id that dropped this row, else NULL
#' }
#'
#' @section Ids:
#' \describe{
#'   \item{Snapshot}{`md5('obs.v1', source, ein, role, name_text_id,
#'     address_text_id, first_seen)`: one id per spell, so a value that comes
#'     back after a change opens a new spell.}
#'   \item{Every other kind}{`md5('obs.v1', source, record_key, row_hash,
#'     occurrence)`, where `row_hash = md5('row.v1', ein, role, name_text_id,
#'     address_text_id, asserted_by, period)` and `occurrence` numbers rows
#'     identical in all of those within one record. A corrected value in a
#'     re-released filing is therefore a new row, and the old one is retracted,
#'     rather than an update the diff cannot see.}
#' }
#'
#' @param con A DuckDB connection.
#' @name md_ledger
NULL

#' @rdname md_ledger
#' @return `md_ledger_schema()`: `con`, invisibly.
#' @export
md_ledger_schema <- function(con) {
  md_text_schema(con)
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS obs (
      obs_id VARCHAR PRIMARY KEY, source VARCHAR NOT NULL, kind VARCHAR NOT NULL,
      part VARCHAR, ein VARCHAR NOT NULL, role VARCHAR NOT NULL,
      name_text_id VARCHAR, address_text_id VARCHAR, asserted_by VARCHAR,
      record_key VARCHAR, trace_key VARCHAR, period INTEGER, filed_at VARCHAR,
      first_seen VARCHAR, last_seen VARCHAR, bounds_kind VARCHAR NOT NULL,
      first_release VARCHAR NOT NULL, last_release VARCHAR NOT NULL,
      retracted_in VARCHAR)")
  invisible(con)
}

# The columns a parser returns. ein, role and record_key are required; the rest
# are filled with NULL when a parser has no such field.
.md_frame_cols <- c("ein", "role", "name_raw", "street_raw", "unit_raw", "city_raw",
                    "state", "zip5", "zip_plus4", "asserted_by", "record_key",
                    "trace_key", "period", "filed_at", "first_seen", "last_seen")

#' Fold one release of a source into the ledger
#'
#' Takes a parsed release - a table or view with the standard frame columns
#' (see the `md_parse_*()` functions) - and applies the update rule for the
#' source's kind ([md_source_kinds()]), in one transaction:
#'
#' \describe{
#'   \item{series, mentions, cache, seed}{Diff against the ledger rows of this
#'     source and partition: new rows are inserted, rows already present have
#'     `last_release` moved to this release, and rows this release no longer
#'     carries get `retracted_in`. A retracted row that comes back is
#'     un-retracted. A new partition is all inserts.}
#'   \item{snapshot}{Compare against the spells left open by the source's
#'     previous release: an unchanged value extends its spell, a new or changed
#'     value opens one, and a value that is missing is left closed. Releases
#'     must arrive in vintage order; an older one is refused, because the fix
#'     for a missed release is a replay, not a back-fill.}
#' }
#'
#' Applying the same release twice changes nothing. For a snapshot, the second
#' application is reported as already applied; for the other kinds the diff
#' simply finds nothing to do.
#'
#' @param frame A table or view in `con` with the standard frame columns.
#' @param source A source from [md_sources()].
#' @param version The pinned version.
#' @param part The partition (tax year), or `NA`.
#' @param vintage What the release describes, as a sortable string
#'   (`"2026-07"`). Defaults to `version`. Orders snapshot releases.
#' @param file_md5 The md5 of the file read. If a release with this id was
#'   already applied from a file with the same md5, nothing is done.
#' @return A one-row data frame, invisibly: `status` (`applied`, `unchanged`
#'   or `already_applied`), `n_rows`, `n_new`, `n_kept`, `n_retracted`.
#' @export
md_apply_release <- function(con, frame, source, version, part = NA,
                             vintage = version, file_md5 = NA) {
  src <- md_sources()
  if (!source %in% src$source) stop("unknown source: ", source, call. = FALSE)
  kind <- src$kind[src$source == source]
  md_ledger_schema(con)
  md_identity_macros(con)
  .md_ledger_macros(con)
  part <- if (is.na(part)) NA_character_ else as.character(part)
  rid <- md_release_id(source, version, part)
  lit <- function(x) if (is.na(x)) "NULL" else DBI::dbQuoteString(con, x)
  result <- function(status, n = c(0, 0, 0, 0)) invisible(data.frame(
    source = source, version = version, part = part, status = status,
    n_rows = n[1], n_new = n[2], n_kept = n[3], n_retracted = n[4],
    stringsAsFactors = FALSE))

  prior <- DBI::dbGetQuery(con, sprintf(
    "SELECT file_md5, seq FROM release WHERE release_id = %s", lit(rid)))
  if (nrow(prior) && !is.na(file_md5) && identical(prior$file_md5, file_md5)) {
    return(result("unchanged"))
  }
  if (kind == "snapshot") {
    last <- DBI::dbGetQuery(con, sprintf(
      "SELECT release_id, vintage FROM release WHERE source = %s ORDER BY seq DESC LIMIT 1",
      lit(source)))
    if (nrow(prior)) {
      if (nrow(last) && last$release_id == rid && (is.na(file_md5) || is.na(prior$file_md5))) {
        return(result("already_applied"))
      }
      stop(source, " ", version, " was already applied", if (!is.na(file_md5))
        " from a different file", ". A snapshot cannot be re-applied out of order; replay ",
        "the source from its first release.", call. = FALSE)
    }
    if (nrow(last) && !(vintage > last$vintage)) {
      stop(source, " ", vintage, " is not newer than the last release applied (",
           last$vintage, "). Snapshot releases must arrive in order; replay to insert one.",
           call. = FALSE)
    }
  }

  .md_frame_in(con, frame)
  n <- NULL
  DBI::dbWithTransaction(con, {
    md_add_text(con, "(SELECT name_raw FROM rel_in WHERE name_raw IS NOT NULL)", "name")
    md_add_text(con, "(SELECT street_raw, unit_raw, city_raw, state, zip5, zip_plus4 FROM rel_in)",
                "address")
    .md_rel_obs(con, kind, source, vintage)
    n <- if (kind == "snapshot") .md_apply_snapshot(con, source, rid, vintage, lit)
         else .md_apply_partition(con, source, rid, part, vintage, lit)
    seq <- if (nrow(prior)) prior$seq else DBI::dbGetQuery(con,
      "SELECT coalesce(max(seq), 0) + 1 AS s FROM release")$s
    DBI::dbExecute(con, sprintf("DELETE FROM release WHERE release_id = %s", lit(rid)))
    DBI::dbExecute(con, sprintf(
      "INSERT INTO release VALUES (%s, %s, %s, %s, %s, %s, %s, %d, %s, current_timestamp)",
      lit(rid), lit(source), lit(kind), lit(version), lit(part), lit(vintage),
      lit(file_md5), as.integer(seq), format(n[1], scientific = FALSE)))
  })
  result("applied", n)
}

# Copy the parser's frame into rel_in with every standard column present.
.md_frame_in <- function(con, frame) {
  have <- names(DBI::dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", frame)))
  need <- c("ein", "role", "record_key")
  if (length(setdiff(need, have))) {
    stop("frame lacks required column(s): ", paste(setdiff(need, have), collapse = ", "),
         call. = FALSE)
  }
  sel <- vapply(.md_frame_cols, function(col) {
    if (col == "period") {
      if (col %in% have) "TRY_CAST(period AS INTEGER) AS period" else "CAST(NULL AS INTEGER) AS period"
    } else if (col %in% have) sprintf('CAST("%s" AS VARCHAR) AS "%s"', col, col)
    else sprintf('CAST(NULL AS VARCHAR) AS "%s"', col)
  }, character(1))
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE rel_in AS SELECT %s FROM %s
                               WHERE ein IS NOT NULL", paste(sel, collapse = ", "), frame))
}

# Hash the release's rows into rel_obs, with the obs_id each would have.
.md_rel_obs <- function(con, kind, source, vintage) {
  q <- function(x) DBI::dbQuoteString(con, x)
  stated <- if (kind == "seed") "'envelope'" else "'stated'"
  bounds <- switch(kind, snapshot = "'spell'",
    sprintf("CASE WHEN first_seen IS NOT NULL OR last_seen IS NOT NULL THEN %s ELSE 'period' END",
            stated))
  id <- if (kind == "snapshot") {
    sprintf("md_hash_id_6('obs.v1', %s, ein, role, name_text_id, address_text_id, %s)",
            q(source), q(vintage))
  } else {
    sprintf("md_hash_id_4('obs.v1', %s, record_key, row_hash, occurrence)", q(source))
  }
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE rel_obs AS
    WITH t AS (
      SELECT *,
        CASE WHEN md_canon(name_raw) <> '' THEN md_name_text_id(name_raw) END AS name_text_id,
        CASE WHEN md_canon(street_raw) || md_canon(unit_raw) || md_canon(city_raw) ||
                  md_canon(state) || md_canon(zip5) || md_canon(zip_plus4) <> ''
             THEN md_address_text_id(street_raw, unit_raw, city_raw, state, zip5, zip_plus4)
        END AS address_text_id
      FROM rel_in
    ), h AS (
      SELECT *, md_hash_id_6('row.v1', ein, role, name_text_id, address_text_id,
                             asserted_by, period) AS row_hash
      FROM t WHERE name_text_id IS NOT NULL OR address_text_id IS NOT NULL
    ), o AS (
      SELECT *, row_number() OVER (PARTITION BY record_key, row_hash
                                   ORDER BY trace_key NULLS LAST, first_seen NULLS LAST,
                                            last_seen NULLS LAST, filed_at NULLS LAST) AS occurrence
      FROM h
    )
    SELECT %s AS obs_id, ein, role, name_text_id, address_text_id, asserted_by,
           record_key, trace_key, period, filed_at, first_seen, last_seen,
           %s AS bounds_kind
    FROM o", id, bounds))
  if (kind == "snapshot") {
    # one row per value: a snapshot that lists the same value twice says it once
    DBI::dbExecute(con, "
      CREATE OR REPLACE TEMP TABLE rel_obs AS
      SELECT * FROM rel_obs
      QUALIFY row_number() OVER (PARTITION BY obs_id ORDER BY record_key, trace_key) = 1")
  }
  dup <- DBI::dbGetQuery(con,
    "SELECT count(*) - count(DISTINCT obs_id) AS d FROM rel_obs")$d
  if (dup > 0) stop("the release produced ", dup, " repeated observation id(s)", call. = FALSE)
  invisible(NULL)
}

.md_apply_partition <- function(con, source, rid, part, vintage, lit) {
  scope <- sprintf("source = %s AND part IS NOT DISTINCT FROM %s", lit(source), lit(part))
  n_rows <- .md_n(con, "rel_obs")
  n_kept <- DBI::dbGetQuery(con, sprintf(
    "SELECT count(*) AS n FROM obs WHERE %s AND obs_id IN (SELECT obs_id FROM rel_obs)", scope))$n
  # present again: move last_release; un-retract; refresh a range the source states
  DBI::dbExecute(con, sprintf("
    UPDATE obs SET last_release = %s, retracted_in = NULL,
      last_seen  = CASE WHEN obs.bounds_kind IN ('stated', 'envelope') THEN r.last_seen ELSE %s END,
      first_seen = CASE WHEN obs.bounds_kind IN ('stated', 'envelope') THEN r.first_seen ELSE obs.first_seen END
    FROM rel_obs r
    WHERE obs.obs_id = r.obs_id AND obs.source = %s AND obs.part IS NOT DISTINCT FROM %s",
    lit(rid), lit(vintage), lit(source), lit(part)))
  n_retracted <- DBI::dbExecute(con, sprintf("
    UPDATE obs SET retracted_in = %s
    WHERE %s AND retracted_in IS NULL AND obs_id NOT IN (SELECT obs_id FROM rel_obs)",
    lit(rid), scope))
  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO obs
    SELECT obs_id, %s, %s, %s, ein, role, name_text_id,
           address_text_id, asserted_by, record_key, trace_key, period, filed_at,
           CASE WHEN bounds_kind IN ('stated', 'envelope') THEN first_seen ELSE %s END,
           CASE WHEN bounds_kind IN ('stated', 'envelope') THEN last_seen  ELSE %s END,
           bounds_kind, %s, %s, NULL
    FROM rel_obs WHERE obs_id NOT IN (SELECT obs_id FROM obs)",
    lit(source), lit(.md_kind_of(source)), lit(part), lit(vintage), lit(vintage),
    lit(rid), lit(rid)))
  c(n_rows, n_new, n_kept, n_retracted)
}

.md_apply_snapshot <- function(con, source, rid, vintage, lit) {
  prev <- DBI::dbGetQuery(con, sprintf(
    "SELECT release_id FROM release WHERE source = %s ORDER BY seq DESC LIMIT 1",
    lit(source)))$release_id
  prev <- if (length(prev)) prev else NA_character_
  match <- "o.ein = r.ein AND o.role = r.role
            AND o.name_text_id IS NOT DISTINCT FROM r.name_text_id
            AND o.address_text_id IS NOT DISTINCT FROM r.address_text_id"
  # fixed before anything changes: which of this release's values continue an open spell
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE snap_cont AS
    SELECT o.obs_id AS open_id, r.obs_id AS rel_id
    FROM obs o JOIN rel_obs r ON %s
    WHERE o.source = %s AND o.last_release IS NOT DISTINCT FROM %s AND o.retracted_in IS NULL",
    match, lit(source), lit(prev)))
  n_rows <- .md_n(con, "rel_obs")
  n_kept <- DBI::dbExecute(con, sprintf("
    UPDATE obs SET last_release = %s, last_seen = %s
    WHERE obs_id IN (SELECT open_id FROM snap_cont)", lit(rid), lit(vintage)))
  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO obs
    SELECT obs_id, %s, 'snapshot', NULL, ein, role, name_text_id, address_text_id,
           asserted_by, record_key, trace_key, period, filed_at, %s, %s, 'spell',
           %s, %s, NULL
    FROM rel_obs WHERE obs_id NOT IN (SELECT rel_id FROM snap_cont)
      AND obs_id NOT IN (SELECT obs_id FROM obs)",
    lit(source), lit(vintage), lit(vintage), lit(rid), lit(rid)))
  c(n_rows, n_new, n_kept, 0)
}

.md_kind_of <- function(source) {
  s <- md_sources(); s$kind[s$source == source]
}

# Helpers the parsers share. md_ein2(x): any EIN spelling to EIN2, NULL if it
# is not 1-9 digits (a mangled identifier is dropped, never coerced).
# md_digits(x): the digits of x, '' if none.
.md_ledger_macros <- function(con) {
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP MACRO md_digits(x) AS
    regexp_replace(coalesce(CAST(x AS VARCHAR), ''), '[^0-9]', '', 'g')")
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP MACRO md_ein2(x) AS
    CASE WHEN length(md_digits(x)) BETWEEN 1 AND 9 THEN
      'EIN-' || substr(lpad(md_digits(x), 9, '0'), 1, 2) || '-' ||
                substr(lpad(md_digits(x), 9, '0'), 3, 7) END")
  # whatever type a column arrived as, is there any text in it?
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP MACRO md_nonblank(x) AS
    coalesce(trim(CAST(x AS VARCHAR)), '') <> ''")
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP MACRO md_zip5(x) AS
    nullif(substr(md_digits(x), 1, 5), '')")
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP MACRO md_zip4(x) AS
    CASE WHEN length(md_digits(x)) = 9 THEN substr(md_digits(x), 6, 4) END")
  invisible(con)
}
