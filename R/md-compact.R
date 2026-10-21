#' Source-bit registries for `source_mask`
#'
#' A bitmask computed fresh per compaction run is a hazard: add a source
#' mid-project and every existing bit shifts. These are frozen registries, in
#' the same spirit as [md_layers()] (`PLAN.md` section 3a) — a new source
#' appends a new bit; nothing already assigned ever moves.
#'
#' @return A named integer vector, source name to bit value.
#' @export
md_name_sources <- function() {
  c(bmf = 1L, efile990 = 2L, f1023ez = 4L, schedi = 8L, schedr = 16L)
}

#' @rdname md_name_sources
#' @export
md_address_sources <- function() {
  c(bmf = 1L, efile990 = 2L, f1023ez = 4L, schedi = 8L, schedr = 16L,
    meta_address = 32L)
}

# A SQL CASE expression mapping `source` to its registry bit, so the mapping
# lives in one place (the registry function) rather than being retyped in SQL.
.md_source_bit_case <- function(registry) {
  when <- vapply(names(registry), function(s) {
    sprintf("WHEN source = '%s' THEN %d", s, registry[[s]])
  }, character(1))
  sprintf("CASE %s ELSE 0 END", paste(when, collapse = " "))
}

# variant_class precedence: lower rank wins when collapsing across sources.
# in_care_of is deliberately absent -- it is excluded before ranking, not
# ranked, per REDUCTION.md section 4 (it names a person, not an organisation).
.md_variant_rank_case <- function() {
  "CASE variant_class
     WHEN 'legal' THEN 1 WHEN 'dba' THEN 2 WHEN 'division' THEN 3
     WHEN 'observed' THEN 4 WHEN 'former' THEN 5 ELSE 9 END"
}
.md_rank_to_variant <- c("1" = "legal", "2" = "dba", "3" = "division",
                         "4" = "observed", "5" = "former")

#' Build the compact identity tables
#'
#' Collapses `name` to one row per `(ein, name_key)` and `address` to one row
#' per `(ein, street_key, city_key, state, zip5)` after domination pruning.
#' Every contributing raw row is untouched — this is a derived layer beside
#' [md_build_derived()]'s `name_derived`/`address_derived`, not a replacement.
#' See `dev/COMPACTION.md` for the process this implements and what it
#' measured against the real database.
#'
#' @section Why DROP-and-rebuild rather than update in place:
#' If the ranking rule changes, the correct response is `DROP TABLE` and
#' rebuild, the same posture `md_build_derived()` takes toward normalizer
#' drift (section 9) — never an in-place reconciliation against tables meant to
#' stay append-only.
#'
#' @section Guarded observed rows:
#' [md_guard_observed()] flags observed names written for the wrong EIN
#' (`name.guard_any`). By default those rows, and the observed addresses paired
#' with them through `name_id`, are left out **before** collapsing. A key also
#' backed by an unflagged row (the BMF legal name, say) survives, carried by
#' that row alone; a key backed only by flagged rows disappears. Raw rows in
#' `name` and `address` are untouched either way.
#'
#' With `drop_guarded = FALSE` every row is kept, and `guard_any` on the compact
#' row is `TRUE` only when **every** row behind it was flagged, so a spec can
#' still filter on it. In both modes the column exists, so the table's shape
#' does not depend on the option.
#'
#' @param con A connection from [md_db()].
#' @param what Which compact tables to build.
#' @param drop_guarded Leave out observed names flagged by
#'   [md_guard_observed()] and the addresses paired with them. Defaults to
#'   `TRUE`; a database where the guards never ran has no flags and loses nothing.
#' @return Row counts, invisibly.
#' @export
md_build_compact <- function(con = NULL, what = c("name", "address"),
                             drop_guarded = TRUE) {
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  out <- integer(0)

  # name_compact joins name_derived; a stale derived table degrades this to a
  # silent partial join rather than an error (?md_check_derived_fresh).
  # address_compact does not join address_derived and is unaffected, but the
  # check costs one query and catches drift before it is trusted either way.
  if ("name" %in% what) md_check_derived_fresh(con)

  if ("name" %in% what) out["name"] <- .md_compact_name(con, msg, drop_guarded)
  if ("address" %in% what) out["address"] <- .md_compact_address(con, msg, drop_guarded)
  invisible(out)
}

# SQL for "this name row is flagged". A database built before the guards (or
# where they never ran) has no guard_any column: nothing is flagged, rather
# than an error.
.md_guarded_sql <- function(con, alias = "n") {
  if ("guard_any" %in% DBI::dbListFields(con, "name")) {
    sprintf("coalesce(%s.guard_any, false)", alias)
  } else {
    "false"
  }
}

.md_compact_name <- function(con, msg, drop_guarded = TRUE) {
  bit_case <- .md_source_bit_case(md_name_sources())
  rank_case <- .md_variant_rank_case()
  guarded <- .md_guarded_sql(con, "n")

  n_excluded <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM name WHERE variant_class = 'in_care_of'")$n
  msg("name: excluding %s in_care_of rows (not an organisation identity)",
      format(n_excluded, big.mark = ","))
  n_guarded <- DBI::dbGetQuery(con, sprintf(
    "SELECT count(*) AS n FROM name n WHERE n.variant_class <> 'in_care_of' AND %s",
    guarded))$n
  msg("name: %s observed rows flagged by md_guard_observed() %s",
      format(n_guarded, big.mark = ","),
      if (drop_guarded) "excluded (drop_guarded = TRUE)" else "kept, marked in guard_any")

  DBI::dbExecute(con, "DROP TABLE IF EXISTS name_compact")
  DBI::dbExecute(con, sprintf("
    CREATE TABLE name_compact AS
    WITH keyed AS (
      SELECT n.ein, d.name_key, n.name_raw, n.n_obs, n.n_corroborators,
             n.first_year, n.last_year,
             %s AS source_bit,
             %s AS variant_rank,
             %s AS guarded
      FROM name n
      JOIN name_derived d USING (name_id)
      WHERE d.name_key <> '' AND n.variant_class <> 'in_care_of' AND %s
    ), %s
    , agg AS (
      SELECT ein, name_key,
             sum(n_obs) AS n_obs,
             max(n_corroborators) AS n_corroborators,
             min(first_year) AS first_year,
             max(last_year) AS last_year,
             bit_or(source_bit) AS source_mask,
             min(variant_rank) AS variant_rank,
             count(*) AS n_contributing_rows,
             -- flagged only when every row behind the key was flagged
             bool_and(guarded) AS guard_any
      FROM keyed GROUP BY 1, 2
    )
    SELECT a.ein, a.name_key, s.name_raw, a.variant_rank, a.n_obs,
           a.n_corroborators, a.first_year, a.last_year, a.source_mask,
           a.n_contributing_rows, a.guard_any,
           count(*) OVER (PARTITION BY a.name_key) AS n_eins_sharing
    FROM agg a
    JOIN modal_name_raw s USING (ein, name_key)
    WHERE s.rk = 1",
    bit_case, rank_case, guarded,
    if (drop_guarded) sprintf("NOT %s", guarded) else "TRUE",
    md_modal_sql("keyed", c("ein", "name_key"), "name_raw")))

  # variant_rank -> variant_class as a separate UPDATE rather than a CASE
  # inline above: DuckDB does not let a column alias from one SELECT level
  # feed a window function and a value mapping in the same statement cleanly,
  # and a follow-up UPDATE is one pass over an already-small table.
  DBI::dbExecute(con, "ALTER TABLE name_compact ADD COLUMN variant_class VARCHAR")
  for (r in names(.md_rank_to_variant)) {
    DBI::dbExecute(con, sprintf(
      "UPDATE name_compact SET variant_class = '%s' WHERE variant_rank = %s",
      .md_rank_to_variant[[r]], r))
  }

  n <- .md_n(con, "name_compact")
  n_in <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM name WHERE variant_class <> 'in_care_of'")$n
  msg("name_compact: %s rows from %s eligible input rows (%.1f%% reduction)",
      format(n, big.mark = ","), format(n_in, big.mark = ","),
      100 * (1 - n / n_in))
  n
}

.md_compact_address <- function(con, msg, drop_guarded = TRUE) {
  bit_case <- .md_source_bit_case(md_address_sources())

  # An observed address was written together with a name (the name_id pairing
  # link); when that name is flagged as written for the wrong EIN, so is the
  # address.
  ga_sql <- sprintf("
    SELECT a.address_id FROM address a JOIN name n ON n.name_id = a.name_id
    WHERE %s", .md_guarded_sql(con, "n"))
  n_guarded <- DBI::dbGetQuery(con, sprintf("SELECT count(*) AS n FROM (%s)", ga_sql))$n
  msg("address: %s observed rows paired with a flagged name %s",
      format(n_guarded, big.mark = ","),
      if (drop_guarded) "excluded (drop_guarded = TRUE)" else "kept, marked in guard_any")

  DBI::dbExecute(con, "DROP TABLE IF EXISTS address_compact")
  DBI::dbExecute(con, sprintf("
    CREATE TABLE address_compact AS
    WITH ga AS (%s), keyed AS (
      SELECT ein,
             nullif(upper(trim(street_raw)), '') AS street_key,
             nullif(upper(trim(city_raw)), '')   AS city_key,
             nullif(upper(trim(state)), '')       AS state,
             nullif(zip5, '')                     AS zip5,
             n_obs, n_corroborators,
             TRY_CAST(regexp_extract(coalesce(first_vintage,''), '^[0-9]{4}') AS INTEGER) AS vintage_lo,
             TRY_CAST(regexp_extract(coalesce(last_vintage,''),  '^[0-9]{4}') AS INTEGER) AS vintage_hi,
             %s AS source_bit,
             address_id IN (SELECT address_id FROM ga) AS guarded
      FROM address
      WHERE %s
    ), agg AS (
      SELECT ein, street_key, city_key, state, zip5,
             sum(n_obs) AS n_obs,
             max(n_corroborators) AS n_corroborators,
             min(vintage_lo) AS first_vintage_year,
             max(vintage_hi) AS last_vintage_year,
             bit_or(source_bit) AS source_mask,
             count(*) AS n_contributing_rows,
             bool_and(guarded) AS guard_any
      FROM keyed GROUP BY 1, 2, 3, 4, 5
    ), dominated AS (
      SELECT a.ein, a.street_key, a.city_key, a.state, a.zip5
      FROM agg a
      WHERE a.street_key IS NULL
        AND EXISTS (
          SELECT 1 FROM agg b
          WHERE b.ein = a.ein AND b.street_key IS NOT NULL
            AND (a.city_key IS NULL OR b.city_key = a.city_key)
            AND (a.state     IS NULL OR b.state     = a.state)
            AND (a.zip5      IS NULL OR b.zip5      = a.zip5))
    )
    SELECT a.*
    FROM agg a
    LEFT JOIN dominated x
      ON x.ein = a.ein
     AND x.street_key IS NOT DISTINCT FROM a.street_key
     AND x.city_key   IS NOT DISTINCT FROM a.city_key
     AND x.state       IS NOT DISTINCT FROM a.state
     AND x.zip5        IS NOT DISTINCT FROM a.zip5
    WHERE x.ein IS NULL", ga_sql, bit_case,
    if (drop_guarded) "address_id NOT IN (SELECT address_id FROM ga)" else "TRUE"))

  n <- .md_n(con, "address_compact")
  n_in <- .md_n(con, "address")
  n_exact <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM (
      SELECT DISTINCT ein,
             nullif(upper(trim(street_raw)), '') AS street_key,
             nullif(upper(trim(city_raw)), '')   AS city_key,
             nullif(upper(trim(state)), '')       AS state,
             nullif(zip5, '')                     AS zip5
      FROM address)")$n
  msg("address_compact: %s raw -> %s after exact dedupe -> %s after domination pruning (%.1f%% total reduction)",
      format(n_in, big.mark = ","), format(n_exact, big.mark = ","),
      format(n, big.mark = ","), 100 * (1 - n / n_in))
  n
}
