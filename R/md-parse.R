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
           SI_02_GRANT_US_ORG_ADDR_L1 AS street_raw, SI_02_GRANT_US_ORG_ADDR_L2 AS unit_raw,
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
           ein2 AS record_key FROM b WHERE md_nonblank(org_name_raw)
    UNION ALL
    SELECT ein2, 'dba', dba_name_raw, NULL, NULL, NULL, NULL, NULL, ein2
    FROM b WHERE md_nonblank(dba_name_raw)
    UNION ALL
    SELECT ein2, 'in_care_of', in_care_of_name_raw, NULL, NULL, NULL, NULL, NULL, ein2
    FROM b WHERE md_nonblank(in_care_of_name_raw)
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

#' @rdname md_parse
#' @details Step 5 ports the remaining sources that write names or addresses:
#' \describe{
#'   \item{`md_parse_bmf_unified()`}{seed. Like the monthly BMF, names and the
#'     address are separate rows; each carries the EIN's first and last vintage,
#'     stored as an envelope ("the EIN existed over this range and ended with
#'     this value"), not as a spell.}
#'   \item{`md_parse_f1023ez()`}{series, one partition per approval year. The
#'     legal name with the address, keyed on the EIN.}
#'   \item{`md_parse_efile_related()`}{mentions. Schedule R Part II: each
#'     related organisation's name and address as the filer wrote them.}
#'   \item{`md_parse_affiliate_listing()`}{mentions. A group return's roster:
#'     each subordinate's own name, and from e-file v3_1 its address. A row
#'     needs a full nine-digit member EIN, and a parent listing itself is
#'     dropped, as in [md_ingest_affiliate_listing()].}
#'   \item{`md_parse_e_postcard()`}{snapshot. The legal name and up to three
#'     DBAs, and the address, as separate rows. The postcard's tax year is not
#'     kept: a spell runs across monthly releases, not across postcards.}
#'   \item{`md_parse_revocations()`}{series, one cumulative partition. The
#'     legal name and DBA, each with the address as of revocation, keyed on the
#'     EIN and revocation date; the year revoked is the period.}
#' }
#' @param year For `md_parse_f1023ez()`: the approval year of the file.
#' @export
md_parse_bmf_unified <- function(con, relation, view = "frame_bmf_unified") {
  .md_ledger_macros(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    WITH b AS (SELECT *, md_ein2(EIN2) AS ein2 FROM %s)
    SELECT ein2 AS ein, 'legal' AS role, org_name_raw AS name_raw,
           NULL AS street_raw, NULL AS city_raw, NULL AS state, NULL AS zip5, NULL AS zip_plus4,
           ein2 AS record_key, first_vintage_ym AS first_seen, last_vintage_ym AS last_seen
    FROM b WHERE md_nonblank(org_name_raw)
    UNION ALL
    SELECT ein2, 'dba', dba_name_raw, NULL, NULL, NULL, NULL, NULL, ein2,
           first_vintage_ym, last_vintage_ym
    FROM b WHERE md_nonblank(dba_name_raw)
    UNION ALL
    SELECT ein2, 'in_care_of', in_care_of_name_raw, NULL, NULL, NULL, NULL, NULL, ein2,
           first_vintage_ym, last_vintage_ym
    FROM b WHERE md_nonblank(in_care_of_name_raw)
    UNION ALL
    SELECT ein2, 'mailing', NULL, org_addr_street_raw, org_addr_city_raw, org_addr_state,
           md_zip5(org_addr_zip5), nullif(md_digits(org_addr_zip4), ''), ein2,
           first_vintage_ym, last_vintage_ym
    FROM b", view, relation))
  view
}

#' @rdname md_parse
#' @export
md_parse_f1023ez <- function(con, relation, year, view = "frame_f1023ez") {
  .md_ledger_macros(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    SELECT md_ein2(Ein) AS ein, 'legal' AS role,
           trim(coalesce(Orgname1, '') || ' ' || coalesce(Orgname2, '')) AS name_raw,
           Address AS street_raw, City AS city_raw, State AS state, md_zip5(Zip) AS zip5,
           coalesce(nullif(md_digits(Zippl4), ''), md_zip4(Zip)) AS zip_plus4,
           md_ein2(Ein) AS record_key, %d AS period
    FROM %s
    WHERE md_ein2(Ein) IS NOT NULL", view, as.integer(year), relation))
  view
}

#' @rdname md_parse
#' @export
md_parse_efile_related <- function(con, relation, view = "frame_efile_related") {
  .md_ledger_macros(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    SELECT md_ein2(SR_02_RLTD_ORG_EIN) AS ein, 'observed' AS role,
           trim(coalesce(SR_02_RLTD_ORG_NAME_L1, '') || ' ' ||
                coalesce(SR_02_RLTD_ORG_NAME_L2, '')) AS name_raw,
           SR_02_RLTD_ORG_ADDR_L1 AS street_raw, SR_02_RLTD_ORG_ADDR_L2 AS unit_raw,
           SR_02_RLTD_ORG_ADDR_CITY AS city_raw, SR_02_RLTD_ORG_ADDR_STATE AS state,
           md_zip5(SR_02_RLTD_ORG_ADDR_ZIP) AS zip5, md_zip4(SR_02_RLTD_ORG_ADDR_ZIP) AS zip_plus4,
           md_ein2(EIN2) AS asserted_by, OBJECTID AS record_key, TABLE_ID AS trace_key,
           TAX_YEAR AS period, RETURN_TIME_STAMP AS filed_at
    FROM %s
    WHERE md_ein2(SR_02_RLTD_ORG_EIN) IS NOT NULL
      AND trim(coalesce(SR_02_RLTD_ORG_NAME_L1, '') || coalesce(SR_02_RLTD_ORG_NAME_L2, '')) <> ''",
    view, relation))
  view
}

#' @rdname md_parse
#' @export
md_parse_affiliate_listing <- function(con, relation, view = "frame_affiliate_listing") {
  .md_ledger_macros(con)
  cols <- names(DBI::dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", relation)))
  # Each column checked on its own: the published tables (e-file v3_1) carry
  # the subordinate's address, the older local extract does not, and the 2009
  # table has an address with no second line.
  col <- function(x) if (x %in% cols) x else "NULL"
  addr <- sprintf("%s, %s, %s, %s, md_zip5(%s), md_zip4(%s)",
                  col("F9_00_AFFIL_ADDR_L1"), col("F9_00_AFFIL_ADDR_L2"),
                  col("F9_00_AFFIL_ADDR_CITY"), col("F9_00_AFFIL_ADDR_STATE"),
                  col("F9_00_AFFIL_ADDR_ZIP"), col("F9_00_AFFIL_ADDR_ZIP"))
  name2 <- col("F9_00_AFFIL_NAME_L2")
  filer <- if ("ORG_EIN" %in% cols) "coalesce(ORG_EIN, EIN2)" else "EIN2"
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    SELECT * FROM (
      SELECT md_ein2(F9_00_AFFIL_EIN), 'observed',
             trim(coalesce(F9_00_AFFIL_NAME_L1, '') || ' ' || coalesce(CAST(%s AS VARCHAR), '')),
             %s,
             md_ein2(%s), OBJECTID, TABLE_ID, TAX_YEAR, RETURN_TIME_STAMP
      FROM %s
      WHERE length(md_digits(F9_00_AFFIL_EIN)) = 9 AND length(md_digits(%s)) = 9
    ) AS f (ein, role, name_raw, street_raw, unit_raw, city_raw, state, zip5, zip_plus4,
            asserted_by, record_key, trace_key, period, filed_at)
    WHERE ein <> asserted_by AND name_raw <> ''", view, name2, addr, filer, relation, filer))
  view
}

#' @rdname md_parse
#' @export
md_parse_e_postcard <- function(con, relation, view = "frame_e_postcard") {
  .md_ledger_macros(con)
  # the second address line, kept apart as the unit (dev/PLACES.md section 3)
  line2 <- if ("organization_address_line_2" %in%
               names(DBI::dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", relation)))) {
    "organization_address_line_2"
  } else "NULL"
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    WITH p AS (SELECT *, md_ein2(ein) AS ein2 FROM %s)
    SELECT ein2 AS ein, 'legal' AS role, legal_name AS name_raw,
           NULL AS street_raw, NULL AS unit_raw, NULL AS city_raw, NULL AS state, NULL AS zip5,
           NULL AS zip_plus4, ein2 AS record_key FROM p WHERE md_nonblank(legal_name)
    UNION ALL SELECT ein2, 'dba', dba_name_1, NULL, NULL, NULL, NULL, NULL, NULL, ein2
    FROM p WHERE md_nonblank(dba_name_1)
    UNION ALL SELECT ein2, 'dba', dba_name_2, NULL, NULL, NULL, NULL, NULL, NULL, ein2
    FROM p WHERE md_nonblank(dba_name_2)
    UNION ALL SELECT ein2, 'dba', dba_name_3, NULL, NULL, NULL, NULL, NULL, NULL, ein2
    FROM p WHERE md_nonblank(dba_name_3)
    UNION ALL
    SELECT ein2, 'mailing', NULL, organization_address_line_1, %s, organization_city,
           organization_state, md_zip5(organization_zip), md_zip4(organization_zip), ein2
    FROM p", view, relation, line2))
  view
}

#' @rdname md_parse
#' @export
md_parse_revocations <- function(con, relation, view = "frame_revocations") {
  .md_ledger_macros(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP VIEW %s AS
    WITH r AS (
      SELECT *, md_ein2(ein) AS ein2,
             try_strptime(nullif(trim(revocation_date), ''), '%%d-%%b-%%Y')::DATE AS revoked
      FROM %s
    ), v AS (
      SELECT *, 'legal' AS role, legal_name AS name_raw FROM r
      WHERE md_nonblank(legal_name)
      UNION ALL SELECT *, 'dba', doing_business_as_name FROM r
      WHERE md_nonblank(doing_business_as_name)
    )
    SELECT ein2 AS ein, role, name_raw, organization_address AS street_raw, city AS city_raw,
           state, md_zip5(zip_code) AS zip5, md_zip4(zip_code) AS zip_plus4,
           ein2 || ' ' || coalesce(CAST(revoked AS VARCHAR), trim(revocation_date), '') AS record_key,
           year(revoked) AS period
    FROM v WHERE ein2 IS NOT NULL", view, relation))
  view
}
