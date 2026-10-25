#' Parse a raw source file into a ledger frame
#'
#' Each parser reads one source's raw file, with the publisher's own column
#' names, and returns the name of a temporary view in the standard frame shape
#' [md_apply_release()] takes. Parsing is the whole job: which names and
#' addresses a record states, under which role, with which key. Identity,
#' diffing and writing are the engine's (`dev/IDENTITY.md` §5).
#'
#' Text is passed through as the source wrote it; only structure is parsed
#' (an EIN to `EIN2`, a ZIP into its five and four digits, name lines joined).
#' Case, punctuation and abbreviations are the normalizer's business, in the
#' derived columns.
#'
#' Phase 5 step 4 ports one source of each kind:
#' \describe{
#'   \item{`md_parse_efile_header()`}{series. One frame row per name on the
#'     return - legal, DBA, in care of - each with the return's address.
#'     `record_key` is `OBJECTID`.}
#'   \item{`md_parse_schedi()`}{mentions. One row per grant line: the
#'     recipient's name and address as the filer wrote them, `asserted_by` the
#'     filer. Identical lines in one return are kept, and the engine numbers
#'     them.}
#'   \item{`md_parse_bmf_active()`}{snapshot. Names and the address as separate
#'     rows, so a renamed organisation that did not move keeps its address
#'     spell, and the other way round.}
#'   \item{`md_parse_address_crosswalk()`}{cache. One row per address spell,
#'     with the range the crosswalk states as `first_seen`/`last_seen`.}
#' }
#'
#' @param con A DuckDB connection.
#' @param relation The raw file as a table, view or `read_csv(...)` expression.
#' @param view Name for the temporary view returned.
#' @return The view's name.
#' @name md_parse
NULL

#' @rdname md_parse
#' @export
md_parse_efile_header <- function(con, relation, view = "frame_efile_header") {
  .md_ledger_macros(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    WITH h AS (
      SELECT md_ein2(EIN2) AS ein, OBJECTID AS record_key, TAX_YEAR AS period,
             RETURN_TIME_STAMP AS filed_at,
             trim(coalesce(F9_00_ORG_NAME_L1, ORG_NAME_L1, '') || ' ' ||
                  coalesce(F9_00_ORG_NAME_L2, ORG_NAME_L2, '')) AS legal,
             trim(coalesce(F9_00_ORG_NAME_DBA_L1, '') || ' ' ||
                  coalesce(F9_00_ORG_NAME_DBA_L2, '')) AS dba,
             trim(coalesce(F9_00_ORG_ADDR_IN_CARE_OF, '')) AS ico,
             F9_00_ORG_ADDR_L1 AS street_raw, F9_00_ORG_ADDR_CITY AS city_raw,
             F9_00_ORG_ADDR_STATE AS state, md_zip5(F9_00_ORG_ADDR_ZIP) AS zip5,
             md_zip4(F9_00_ORG_ADDR_ZIP) AS zip_plus4
      FROM %s
    ), v AS (
      SELECT *, 'legal' AS role, legal AS name_raw FROM h WHERE legal <> ''
      UNION ALL SELECT *, 'dba', dba FROM h WHERE dba <> ''
      UNION ALL SELECT *, 'in_care_of', ico FROM h WHERE ico <> ''
    )
    SELECT ein, role, name_raw, street_raw, city_raw, state, zip5, zip_plus4,
           record_key, period, filed_at
    FROM v WHERE ein IS NOT NULL", view, relation))
  view
}

#' @rdname md_parse
#' @export
md_parse_schedi <- function(con, relation, view = "frame_schedi") {
  .md_ledger_macros(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    SELECT md_ein2(SI_02_GRANT_US_ORG_EIN) AS ein, 'observed' AS role,
           trim(coalesce(SI_02_GRANT_US_ORG_NAME_L1, '') || ' ' ||
                coalesce(SI_02_GRANT_US_ORG_NAME_L2, '')) AS name_raw,
           trim(coalesce(SI_02_GRANT_US_ORG_ADDR_L1, '') || ' ' ||
                coalesce(SI_02_GRANT_US_ORG_ADDR_L2, '')) AS street_raw,
           SI_02_GRANT_US_ORG_ADDR_CITY AS city_raw, SI_02_GRANT_US_ORG_ADDR_STATE AS state,
           md_zip5(SI_02_GRANT_US_ORG_ADDR_ZIP) AS zip5,
           md_zip4(SI_02_GRANT_US_ORG_ADDR_ZIP) AS zip_plus4,
           md_ein2(EIN2) AS asserted_by, OBJECTID AS record_key, TABLE_ID AS trace_key,
           TAX_YEAR AS period, RETURN_TIME_STAMP AS filed_at
    FROM %s
    WHERE md_ein2(SI_02_GRANT_US_ORG_EIN) IS NOT NULL
      AND trim(coalesce(SI_02_GRANT_US_ORG_NAME_L1, '') || coalesce(SI_02_GRANT_US_ORG_NAME_L2, '')) <> ''",
    view, relation))
  view
}

#' @rdname md_parse
#' @export
md_parse_bmf_active <- function(con, relation, view = "frame_bmf_active") {
  .md_ledger_macros(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    WITH b AS (SELECT *, md_ein2(ein) AS ein2 FROM %s)
    SELECT ein2 AS ein, 'legal' AS role, org_name_raw AS name_raw,
           NULL AS street_raw, NULL AS city_raw, NULL AS state, NULL AS zip5, NULL AS zip_plus4,
           ein2 AS record_key FROM b WHERE coalesce(trim(org_name_raw), '') <> ''
    UNION ALL
    SELECT ein2, 'dba', dba_name_raw, NULL, NULL, NULL, NULL, NULL, ein2
    FROM b WHERE coalesce(trim(dba_name_raw), '') <> ''
    UNION ALL
    SELECT ein2, 'in_care_of', in_care_of_name_raw, NULL, NULL, NULL, NULL, NULL, ein2
    FROM b WHERE coalesce(trim(in_care_of_name_raw), '') <> ''
    UNION ALL
    SELECT ein2, 'mailing', NULL, org_addr_street_raw, org_addr_city_raw, org_addr_state_raw,
           md_zip5(org_addr_zip_raw), md_zip4(org_addr_zip_raw), ein2
    FROM b", view, relation))
  view
}

#' @rdname md_parse
#' @export
md_parse_address_crosswalk <- function(con, relation, view = "frame_address_crosswalk") {
  .md_ledger_macros(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    SELECT md_ein2(EIN2) AS ein, 'historical' AS role, street AS street_raw,
           city AS city_raw, state, md_zip5(zip5) AS zip5,
           md_ein2(EIN2) AS record_key, spell_rank AS trace_key,
           nullif(first_vintage, '') AS first_seen, nullif(last_vintage, '') AS last_seen
    FROM %s", view, relation))
  view
}
