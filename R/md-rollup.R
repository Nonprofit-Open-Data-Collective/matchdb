#' Build name and address from the ledger
#'
#' Phase 5 step 6 (`dev/IDENTITY.md` §6). The ledger holds every observation;
#' compile, the statistics, the guards, groups and clusters read `name` and
#' `address`. These functions rebuild those two tables from the ledger, in the
#' shape and grain today's ingests write, so everything downstream keeps working:
#'
#' \describe{
#'   \item{`md_build_rollups()`}{Builds `rollup_name` and `rollup_address`
#'     beside the live tables.}
#'   \item{`md_compare_rollups()`}{Row counts per source and class, live
#'     against rollup, and how many rows of each find a match in the other.}
#'   \item{`md_install_rollups()`}{Swaps the rollups in, keeping the old tables
#'     as `name_legacy` and `address_legacy`, and rebuilds `name_derived` and
#'     `address_derived` from the text-keyed columns ([md_link_derived()]).}
#' }
#'
#' @section Grain and columns:
#' One `name` row per `(ein, source, variant_class, light key)`
#' ([md_light_key()]) with the most frequent spelling, as today's ingests group.
#' One `address` row per `(ein, source, class, paired name, street, city, state,
#' ZIP)` under the light key. Every spelling stays in the ledger; these tables
#' are the view compile reads. The columns and source tags are today's
#' (`bmf`, `efile990`, `schedi`, `schedr`, `f1023ez`, `e_postcard`,
#' `revocations`, `meta_address`), plus:
#' \describe{
#'   \item{`name_uid`, `address_uid`}{Content-hash ids, the same on every
#'     rebuild. `name_id` and `address_id` stay integers, because compile joins
#'     on them; they are renumbered on each rebuild, and `name_derived` and
#'     `address_derived` are rebuilt with them, so nothing can be orphaned.}
#'   \item{`name_text_id`, `address_text_id`}{The chosen spelling.}
#'   \item{`n_periods`, `n_mentions`, `n_spells`, `n_support`}{The counts of
#'     §4. `n_support` is the one that measures support for that kind:
#'     distinct years for a first-party series, rows for mentions (only each
#'     filer's latest return for a tax year), spells for a snapshot, `NULL` for
#'     the seed. `n_obs` is set equal to it, so compile's tiebreak reads a
#'     defined quantity rather than today's mix.}
#' }
#'
#' @section What is derived here rather than at ingest:
#' \itemize{
#'   \item `former`: a 990-header legal name whose last year is before the
#'     EIN's latest legal name.
#'   \item A 990-header address is `mailing` if it is the EIN's most recent,
#'     `historical` otherwise.
#'   \item Guard inputs (`n_self_filers`, `filer_ein_lo`, `filer_ein_hi`), from
#'     `asserted_by`. Run [md_guard_observed()] after installing.
#' }
#' Only EINs present in `entity` are kept, as today's ingests do; the count held
#' back is reported. `entity` itself is not rebuilt: the ledger holds names and
#' addresses, not the BMF's other attributes.
#'
#' @section Not carried:
#' The BMF's own `lat`, `lon`, `county`, `cbsa`, `is_po_box` and `n_vintages`
#' are not in the ledger. [md_install_rollups()] copies them from the live
#' `address` row with the same EIN, source and spelling; run
#' `md_ingest_geocode()` after installing, as the build already does, for the
#' census geography.
#'
#' @param con A DuckDB connection.
#' @name md_rollup
NULL

# Ledger source -> today's source tag and address class. NA class: the 990
# header's, decided by recency.
.md_rollup_map <- data.frame(
  source = c("bmf_unified", "bmf_active", "efile_header", "efile_affiliate_listing", "schedi",
             "efile_related", "f1023ez", "e_postcard", "revocations", "address_crosswalk"),
  tag = c("bmf", "bmf", "efile990", "efile990", "schedi", "schedr", "f1023ez", "e_postcard",
          "revocations", "meta_address"),
  addr_class = c("mailing", "mailing", NA, "observed", "observed", "observed", "historical",
                 "mailing", "historical", "historical"),
  stringsAsFactors = FALSE)

#' @rdname md_rollup
#' @return `md_build_rollups()`: row counts, invisibly.
#' @export
md_build_rollups <- function(con) {
  md_identity_macros(con)
  .md_light_key_macro(con)
  msg <- function(...) message(sprintf(...))
  DBI::dbWriteTable(con, "ru_map", .md_rollup_map, temporary = TRUE, overwrite = TRUE)
  has_entity <- DBI::dbExistsTable(con, "entity")

  # Live observations with their text, keys, and whether they count: for
  # mentions, only rows from each filer's latest return for a tax year (§9).
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE ru_obs AS
    WITH o AS (
      SELECT o.*, m.tag, m.addr_class, n.name_raw, a.street_raw, a.unit_raw, a.city_raw,
             a.state, a.zip5, a.zip_plus4,
             first_value(o.record_key) OVER (
               PARTITION BY o.source, o.asserted_by, o.period
               ORDER BY o.filed_at DESC NULLS LAST, o.record_key DESC) AS latest_rk
      FROM obs o JOIN ru_map m USING (source)
      LEFT JOIN name_text n USING (name_text_id)
      LEFT JOIN address_text a USING (address_text_id)
      WHERE o.retracted_in IS NULL
    )
    SELECT *,
      (asserted_by IS NULL OR period IS NULL OR record_key = latest_rk) AS counted,
      CASE WHEN name_text_id IS NOT NULL THEN md_light_key(name_raw) END AS name_lk,
      md_light_key(street_raw) AS street_lk, md_light_key(city_raw) AS city_lk,
      upper(trim(coalesce(state, ''))) AS state_k, coalesce(zip5, '') AS zip5_k,
      CASE WHEN kind IN ('snapshot', 'seed') OR bounds_kind IN ('stated', 'envelope')
           THEN NULL ELSE period END AS yr,
      TRY_CAST(substr(first_seen, 1, 4) AS INTEGER) AS fy_seen,
      TRY_CAST(substr(last_seen, 1, 4) AS INTEGER) AS ly_seen
    FROM o %s", if (has_entity) "WHERE ein IN (SELECT ein FROM entity)" else ""))
  if (has_entity) {
    held <- DBI::dbGetQuery(con, "
      SELECT count(DISTINCT ein) AS n FROM obs
      WHERE retracted_in IS NULL AND ein NOT IN (SELECT ein FROM entity)")$n
    if (held > 0) msg("rollups: %s EIN(s) in the ledger but not in entity held back",
                      format(held, big.mark = ","))
  }
  # source_vintage: each tag's latest release, as source-version
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE ru_vintage AS
    SELECT m.tag, max(r.source || '-' || r.version) AS source_vintage
    FROM release r JOIN ru_map m USING (source)
    WHERE r.seq = (SELECT max(seq) FROM release r2 WHERE r2.source = r.source)
    GROUP BY 1")

  n_name <- .md_rollup_names(con)
  n_addr <- .md_rollup_addresses(con)
  msg("rollup_name: %s rows; rollup_address: %s rows",
      format(n_name, big.mark = ","), format(n_addr, big.mark = ","))
  invisible(c(name = n_name, address = n_addr))
}

# The count columns shared by names and addresses, over a group of ru_obs rows.
.md_rollup_counts <- "
  count(DISTINCT yr) FILTER (WHERE kind IN ('series', 'mentions')) AS n_periods,
  count(*) FILTER (WHERE kind = 'mentions' AND counted) AS n_mentions,
  count(DISTINCT obs_id) FILTER (WHERE kind = 'snapshot') AS n_spells,
  CASE WHEN count(asserted_by) > 0 THEN count(DISTINCT asserted_by) END AS n_corroborators,
  min(kind) AS kind,
  coalesce(min(yr), min(fy_seen) FILTER (WHERE kind = 'snapshot')) AS first_year,
  coalesce(max(yr), max(ly_seen) FILTER (WHERE kind = 'snapshot')) AS last_year,
  min(first_seen) AS first_seen_min, max(last_seen) AS last_seen_max"

.md_rollup_support <- "
  CASE g.kind WHEN 'mentions' THEN g.n_mentions WHEN 'series' THEN g.n_periods
              WHEN 'snapshot' THEN g.n_spells END"

.md_rollup_names <- function(con) {
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE rollup_name AS
    WITH src AS (
      SELECT * FROM ru_obs WHERE name_text_id IS NOT NULL AND name_lk <> ''
    ), g AS (
      SELECT ein, tag, role, name_lk, %s,
        count(DISTINCT asserted_by) FILTER (WHERE asserted_by = ein) AS n_self_filers,
        min(asserted_by) FILTER (WHERE asserted_by <> ein) AS filer_ein_lo,
        max(asserted_by) FILTER (WHERE asserted_by <> ein) AS filer_ein_hi
      FROM src GROUP BY 1, 2, 3, 4
    ), sp AS (  -- the most frequent spelling in each group; ties by the spelling
      SELECT * FROM (
        SELECT ein, tag, role, name_lk, name_text_id, name_raw,
               row_number() OVER (PARTITION BY ein, tag, role, name_lk
                                  ORDER BY count(*) DESC, name_raw) AS rk
        FROM src GROUP BY ein, tag, role, name_lk, name_text_id, name_raw)
      WHERE rk = 1
    ), j AS (
      SELECT g.*, sp.name_text_id, sp.name_raw, %s AS n_support,
        md_hash_id_4('nv.v1', g.ein, g.tag, g.role, g.name_lk) AS name_uid,
        -- a 990-header legal name superseded by a later one is former
        CASE WHEN g.tag = 'efile990' AND g.role = 'legal'
              AND g.last_year < max(CASE WHEN g.tag = 'efile990' AND g.role = 'legal'
                                         THEN g.last_year END) OVER (PARTITION BY g.ein)
             THEN 'former' ELSE g.role END AS variant_class
      FROM g JOIN sp USING (ein, tag, role, name_lk)
    )
    SELECT CAST(row_number() OVER (ORDER BY j.name_uid) AS BIGINT) AS name_id,
           j.name_uid, j.name_text_id, j.ein, j.name_raw, j.variant_class,
           j.tag AS source, v.source_vintage,
           j.n_support AS n_obs, j.n_support, j.n_periods, j.n_mentions, j.n_spells,
           j.n_corroborators, j.first_year, j.last_year,
           j.n_self_filers, j.filer_ein_lo, j.filer_ein_hi, j.name_lk
    FROM j LEFT JOIN ru_vintage v USING (tag)",
    .md_rollup_counts, .md_rollup_support))
  .md_n(con, "rollup_name")
}

.md_rollup_addresses <- function(con) {
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE rollup_address AS
    WITH src AS (
      -- An observed address is one row per (name written, city, state, ZIP),
      -- keeping the commonest street, as md_ingest_schedi() and
      -- md_ingest_schedr() group it. Grouping on the street as well split one
      -- grantee's place into a row per spelling: +42%% Schedule I rows on the
      -- full database, each one more compiled reference row.
      SELECT * REPLACE (CASE WHEN coalesce(addr_class, '') = 'observed' THEN ''
                             ELSE street_lk END AS street_lk),
             coalesce(addr_class, 'recency') AS cls,
             -- an observed address belongs to the name it was written with
             CASE WHEN coalesce(addr_class, '') = 'observed' THEN coalesce(name_lk, '') ELSE '' END AS link_lk
      FROM ru_obs WHERE address_text_id IS NOT NULL
    ), g AS (
      SELECT ein, tag, cls, link_lk, street_lk, city_lk, state_k, zip5_k, %s,
        count(DISTINCT record_key) AS n_records,
        min(TRY_CAST(trace_key AS INTEGER)) AS min_trace
      FROM src GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
    ), sp AS (
      SELECT * FROM (
        SELECT ein, tag, cls, link_lk, street_lk, city_lk, state_k, zip5_k, address_text_id,
               street_raw, unit_raw, city_raw, state, zip5, zip_plus4,
               row_number() OVER (PARTITION BY ein, tag, cls, link_lk, street_lk, city_lk, state_k, zip5_k
                                  ORDER BY count(*) DESC, street_raw, unit_raw NULLS FIRST, city_raw,
                                           state, zip5, zip_plus4) AS rk
        FROM src
        GROUP BY ein, tag, cls, link_lk, street_lk, city_lk, state_k, zip5_k, address_text_id,
                 street_raw, unit_raw, city_raw, state, zip5, zip_plus4)
      WHERE rk = 1
    ), j AS (
      SELECT g.*, sp.address_text_id, sp.street_raw, sp.unit_raw, sp.city_raw, sp.state, sp.zip5,
             sp.zip_plus4,
        %s AS n_support,
        md_hash_id_8('av.v1', g.ein, g.tag, g.cls, g.link_lk, g.street_lk, g.city_lk,
                     g.state_k, g.zip5_k) AS address_uid,
        -- a 990-header address: the EIN's most recent is mailing, older ones historical
        CASE WHEN g.cls = 'recency' THEN row_number() OVER (
               PARTITION BY g.ein, g.tag, g.cls
               ORDER BY g.last_year DESC NULLS LAST, g.n_periods DESC, g.street_lk, g.zip5_k) - 1
             WHEN g.tag = 'meta_address' THEN coalesce(g.min_trace, 0)
             ELSE 0 END AS spell_rank
      FROM g JOIN sp USING (ein, tag, cls, link_lk, street_lk, city_lk, state_k, zip5_k)
    )
    SELECT CAST(row_number() OVER (ORDER BY j.address_uid) AS BIGINT) AS address_id,
           j.address_uid, j.address_text_id, j.ein,
           CAST(NULL AS BIGINT) AS name_id,
           j.street_raw, j.unit_raw, j.city_raw, j.state, j.zip5, j.zip_plus4,
           CASE WHEN j.cls = 'recency' THEN CASE WHEN j.spell_rank = 0 THEN 'mailing' ELSE 'historical' END
                ELSE j.cls END AS variant_class,
           j.spell_rank, j.tag AS source, v.source_vintage,
           j.n_support AS n_obs, j.n_support, j.n_periods, j.n_mentions, j.n_spells,
           j.n_corroborators,
           coalesce(CAST(j.first_year AS VARCHAR), j.first_seen_min) AS first_vintage,
           coalesce(CAST(j.last_year AS VARCHAR), j.last_seen_max) AS last_vintage,
           CAST(NULL AS INTEGER) AS n_vintages, CAST(NULL AS BOOLEAN) AS is_po_box,
           CAST(NULL AS DOUBLE) AS lat, CAST(NULL AS DOUBLE) AS lon,
           CAST(NULL AS VARCHAR) AS county, CAST(NULL AS VARCHAR) AS cbsa,
           j.link_lk
    FROM j LEFT JOIN ru_vintage v USING (tag)",
    .md_rollup_counts, .md_rollup_support))
  # the pairing link: an observed address to the observed name written with it
  DBI::dbExecute(con, "
    UPDATE rollup_address a SET name_id = n.name_id
    FROM rollup_name n
    WHERE a.variant_class = 'observed' AND a.link_lk <> ''
      AND n.ein = a.ein AND n.source = a.source AND n.variant_class = 'observed'
      AND n.name_lk = a.link_lk")
  .md_n(con, "rollup_address")
}

#' @rdname md_rollup
#' @return `md_compare_rollups()`: a data frame per table, source and class:
#'   live rows, rollup rows, and the share of each matched in the other on
#'   (EIN, source, light key).
#' @export
md_compare_rollups <- function(con) {
  .md_light_key_macro(con)
  one <- function(live, roll, key_live, key_roll) {
    DBI::dbGetQuery(con, sprintf("
      WITH l AS (SELECT source, variant_class, ein, %s AS k FROM %s),
           r AS (SELECT source, variant_class, ein, %s AS k FROM %s),
           cl AS (SELECT source, variant_class, count(*) AS live_rows,
                         count(*) FILTER (WHERE EXISTS (SELECT 1 FROM r WHERE r.ein = l.ein
                           AND r.source = l.source AND r.k = l.k)) AS live_matched
                  FROM l GROUP BY 1, 2),
           cr AS (SELECT source, variant_class, count(*) AS rollup_rows,
                         count(*) FILTER (WHERE EXISTS (SELECT 1 FROM l WHERE l.ein = r.ein
                           AND l.source = r.source AND l.k = r.k)) AS rollup_matched
                  FROM r GROUP BY 1, 2)
      SELECT '%s' AS tbl, coalesce(cl.source, cr.source) AS source,
             coalesce(cl.variant_class, cr.variant_class) AS variant_class,
             coalesce(live_rows, 0) AS live_rows, coalesce(rollup_rows, 0) AS rollup_rows,
             round(100.0 * live_matched / nullif(live_rows, 0), 1) AS pct_live_matched,
             round(100.0 * rollup_matched / nullif(rollup_rows, 0), 1) AS pct_rollup_matched
      FROM cl FULL JOIN cr ON cl.source = cr.source AND cl.variant_class = cr.variant_class
      ORDER BY 2, 3", key_live, live, key_roll, roll, live))
  }
  rbind(
    one("name", "rollup_name", "md_light_key(name_raw)", "md_light_key(name_raw)"),
    one("address", "rollup_address",
        "md_light_key(street_raw) || '|' || md_light_key(city_raw) || '|' || coalesce(zip5, '')",
        "md_light_key(street_raw) || '|' || md_light_key(city_raw) || '|' || coalesce(zip5, '')"))
}

#' @rdname md_rollup
#' @param keep_legacy Keep the replaced tables as `name_legacy` and
#'   `address_legacy` (replacing any earlier legacy copy).
#' @return `md_install_rollups()`: `con`, invisibly.
#' @export
md_install_rollups <- function(con, keep_legacy = TRUE) {
  for (t in c("rollup_name", "rollup_address")) {
    if (!DBI::dbExistsTable(con, t)) stop(t, " does not exist: run md_build_rollups() first",
                                          call. = FALSE)
  }
  # Refuse before touching anything: a swap whose derived link then fails would
  # leave compile reading tables with no derived columns.
  .md_check_rollup_derived(con)
  DBI::dbWithTransaction(con, {
    .md_carry_address_attrs(con)
    for (t in c("name", "address")) {
      DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s_legacy", t))
      if (DBI::dbExistsTable(con, t)) {
        if (keep_legacy) DBI::dbExecute(con, sprintf("ALTER TABLE %s RENAME TO %s_legacy", t, t))
        else DBI::dbExecute(con, sprintf("DROP TABLE %s", t))
      }
      DBI::dbExecute(con, sprintf("ALTER TABLE rollup_%s RENAME TO %s", t, t))
    }
  })
  md_link_derived(con)
  invisible(con)
}

# Attributes the ledger does not hold - the BMF's own geography, its PO-box
# flag and vintage count - copied from the live address table onto the rollup
# row with the same EIN, source and spelling. Only blanks are filled, and each
# rollup row takes one live row's values.
.md_carry_address_attrs <- function(con) {
  if (!DBI::dbExistsTable(con, "address")) return(invisible(0))
  live <- DBI::dbListFields(con, "address")
  cols <- intersect(c("lat", "lon", "county", "cbsa", "is_po_box", "n_vintages"), live)
  keys <- c("ein", "source", "street_raw", "city_raw", "state", "zip5")
  if (!length(cols) || !all(keys %in% live)) return(invisible(0))
  # the ledger writes blanks where ingests wrote NULLs, and collapses runs of
  # spaces (md_canon), so keys are compared that way
  k <- function(p, col) sprintf("trim(regexp_replace(coalesce(%s%s, ''), '\\s+', ' ', 'g'))", p, col)
  # each value in the rollup's type: today's BMF ingest stores is_po_box as text
  ty <- DBI::dbGetQuery(con, "SELECT column_name, data_type FROM duckdb_columns()
                              WHERE table_name = 'rollup_address' AND NOT internal")
  ty <- stats::setNames(ty$data_type, ty$column_name)[cols]
  n <- DBI::dbExecute(con, sprintf("
    UPDATE rollup_address r SET %s
    FROM (SELECT %s, %s FROM address
          WHERE %s
          GROUP BY ALL) o
    WHERE %s",
    paste(sprintf("%s = coalesce(r.%s, TRY_CAST(o.%s AS %s))", cols, cols, cols, ty), collapse = ", "),
    paste(sprintf("%s AS k_%s", k("", keys), keys), collapse = ", "),
    paste(sprintf("any_value(%s) AS %s", cols, cols), collapse = ", "),
    paste(sprintf("%s IS NOT NULL", cols), collapse = " OR "),
    paste(sprintf("%s = o.k_%s", k("r.", keys), keys), collapse = " AND ")))
  invisible(n)
}

# Every spelling the rollups show has derived columns under the signature.
.md_check_rollup_derived <- function(con, signature = npnormalize::np_normalize_signature()) {
  sig <- DBI::dbQuoteString(con, signature)
  for (p in list(c("rollup_name", "name_text_id", "name_text_derived"),
                 c("rollup_address", "address_text_id", "address_text_derived"))) {
    if (!DBI::dbExistsTable(con, p[3])) stop(sprintf(
      "%s does not exist. Run md_build_text_derived() before installing.", p[3]), call. = FALSE)
    missing <- DBI::dbGetQuery(con, sprintf(
      "SELECT count(*) AS n FROM %s WHERE %s IS NOT NULL AND %s NOT IN
         (SELECT %s FROM %s WHERE normalize_signature = %s)",
      p[1], p[2], p[2], p[2], p[3], sig))$n
    if (missing > 0) stop(sprintf(
      "%s %s row(s) show a spelling with no derived row for %s. Run md_build_text_derived() before installing.",
      format(missing, big.mark = ","), p[1], signature), call. = FALSE)
  }
  invisible(TRUE)
}

#' Rebuild name_derived and address_derived from the text-keyed columns
#'
#' After [md_install_rollups()], every `name` and `address` row names the
#' spelling it shows (`name_text_id`, `address_text_id`), whose derived columns
#' [md_build_text_derived()] stored once. This writes `name_derived` and
#' `address_derived`, keyed on the integer ids compile joins on, by a join -
#' seconds, against the hour [md_build_derived()] takes to normalize every row.
#' A spelling with no derived row for the signature is an error, not a gap.
#'
#' @param con A DuckDB connection.
#' @param signature The normalizer signature to read. Defaults to the installed
#'   npmatch's.
#' @return Row counts, invisibly.
#' @export
md_link_derived <- function(con, signature = npnormalize::np_normalize_signature()) {
  sig <- DBI::dbQuoteString(con, signature)
  one <- function(tbl, id, text_id, dtable, cols) {
    if (!DBI::dbExistsTable(con, dtable)) stop(sprintf(
      "%s does not exist. Run md_build_text_derived() before linking.", dtable), call. = FALSE)
    missing <- DBI::dbGetQuery(con, sprintf(
      "SELECT count(*) AS n FROM %s t WHERE %s IS NOT NULL AND %s NOT IN
         (SELECT %s FROM %s WHERE normalize_signature = %s)",
      tbl, text_id, text_id, text_id, dtable, sig))$n
    if (missing > 0) stop(sprintf(
      "%s %s row(s) show a spelling with no derived row for %s. Run md_build_text_derived().",
      format(missing, big.mark = ","), tbl, signature), call. = FALSE)
    DBI::dbExecute(con, sprintf("
      CREATE OR REPLACE TABLE %s_derived AS
      SELECT CAST(t.%s AS INTEGER) AS %s, %s, d.normalize_signature
      FROM %s t JOIN %s d ON d.%s = t.%s AND d.normalize_signature = %s",
      tbl, id, id, paste(sprintf("d.%s", cols), collapse = ", "),
      tbl, dtable, text_id, text_id, sig))
  }
  n <- c(name = one("name", "name_id", "name_text_id", "name_text_derived", .md_derived_name_cols),
         address = one("address", "address_id", "address_text_id", "address_text_derived",
                       .md_address_cols()))
  invisible(n)
}
