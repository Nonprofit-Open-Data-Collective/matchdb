#' Build `ein_key`: every identifier an EIN holds, with how specific it is
#'
#' One long table of the keys a matcher can block on, so a hard case can find
#' candidates through something other than its name: a shared place or a
#' website. One row per `(ein, kind, key)`.
#'
#' \describe{
#'   \item{`name`}{`name_key` from `name_compact` - legal, dba, observed and
#'     former names, without in-care-of names or guarded observed rows}
#'   \item{`place`}{`street_key|zip5` from `address_compact`}
#'   \item{`website`}{`site_key` from `website`, `kind = 'url'`}
#'   \item{`email_domain`}{`site_key` from `website`, `kind = 'email'`}
#' }
#'
#' \describe{
#'   \item{`person`}{an officer, director or key employee's name key from
#'     `person_key` ([md_ingest_officers()]), when that table exists}
#' }
#'
#' @section How specific a key is:
#' `n_eins_sharing` counts the EINs holding the key, across the whole database.
#' A key held by one EIN can propose a candidate on its own; a key held by
#' thousands (`1 WATERFOWL WAY|38120`, `ptk.org`) can only confirm one found
#' another way.
#'
#' The whole-database count answers "is this key ambiguous in the universe".
#' A matcher comparing against a selection of layers needs the count within the
#' selection, so [md_build_ein_key()] also writes `ein_key_layer`: the count per
#' `(kind, key, layer)`. Layers partition EINs - each EIN has exactly one - so
#' the count for any set of layers is the exact sum of its rows.
#'
#' @section Rebuild after its inputs:
#' Derived from `name_compact`, `address_compact` and `website`, so it is
#' rebuilt after them, by DROP and CREATE.
#'
#' @param con A connection from [md_db()].
#' @return Rows per kind, invisibly.
#' @export
md_build_ein_key <- function(con = NULL) {
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  for (t in c("name_compact", "address_compact", "website", "entity")) {
    if (!DBI::dbExistsTable(con, t)) {
      stop(t, " does not exist - build it before ein_key", call. = FALSE)
    }
  }

  # person keys only for EINs in entity, like every other kind
  person <- if (DBI::dbExistsTable(con, "person_key"))
    "UNION ALL
      SELECT p.ein, 'person', p.person_key, 1, p.first_year, p.last_year
      FROM person_key p JOIN entity e USING (ein)" else ""
  .md_placeholder_macro(con)
  DBI::dbExecute(con, "DROP TABLE IF EXISTS ein_key")
  DBI::dbExecute(con, sprintf("
    CREATE TABLE ein_key AS
    WITH k AS (
      SELECT ein, 'name' AS kind, name_key AS key,
             bit_count(source_mask) AS n_sources, first_year, last_year
      FROM name_compact WHERE name_key <> ''
      UNION ALL
      SELECT ein, 'place', street_key || '|' || zip5,
             bit_count(source_mask), first_vintage_year, last_vintage_year
      FROM address_compact
      WHERE street_key <> '' AND coalesce(zip5, '') <> ''
      UNION ALL
      SELECT ein, CASE WHEN kind = 'email' THEN 'email_domain' ELSE 'website' END,
             site_key, count(DISTINCT source), min(first_year), max(last_year)
      FROM website GROUP BY ein, kind, site_key
      %s
    ), one AS (
      SELECT ein, kind, key, max(n_sources) AS n_sources,
             min(first_year) AS first_year, max(last_year) AS last_year
      FROM k WHERE NOT md_placeholder_ein(ein) GROUP BY ein, kind, key
    ), sharing AS (
      SELECT kind, key, count(*) AS n_eins_sharing FROM one GROUP BY kind, key
    )
    SELECT one.*, s.n_eins_sharing
    FROM one JOIN sharing s USING (kind, key)
    ORDER BY kind, key, ein", person))

  DBI::dbExecute(con, "DROP TABLE IF EXISTS ein_key_layer")
  DBI::dbExecute(con, "
    CREATE TABLE ein_key_layer AS
    SELECT k.kind, k.key, e.layer, count(*) AS n_eins
    FROM ein_key k JOIN entity e USING (ein)
    GROUP BY k.kind, k.key, e.layer")

  out <- DBI::dbGetQuery(con, "
    SELECT kind, count(*) AS rows, count(DISTINCT ein) AS eins,
           count(DISTINCT key) AS keys,
           count(DISTINCT key) FILTER (WHERE n_eins_sharing = 1) AS unique_keys
    FROM ein_key GROUP BY kind ORDER BY kind")
  for (i in seq_len(nrow(out))) {
    msg("  ein_key %-12s %s rows over %s EINs; %s keys, %s held by one EIN",
        out$kind[i], format(out$rows[i], big.mark = ","),
        format(out$eins[i], big.mark = ","), format(out$keys[i], big.mark = ","),
        format(out$unique_keys[i], big.mark = ","))
  }
  msg("  ein_key_layer %s rows", format(.md_n(con, "ein_key_layer"), big.mark = ","))
  invisible(stats::setNames(out$rows, out$kind))
}
