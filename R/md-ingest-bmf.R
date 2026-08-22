#' Ingest the unified BMF into entity, name and address
#'
#' Reads the pinned BMF parquet and writes the three core tables. Idempotent:
#' a full load keyed on `source_vintage`, per §10, so re-running replaces rather
#' than accumulating.
#'
#' @section What this does and does not populate:
#' The BMF is a snapshot, not a panel (§4), so this fills the identity spine and
#' the *current* name and address. It writes the resolved-attribute columns as
#' `NULL` and leaves them for `md_ingest_ntee()`, which reads the canonical NTEE
#' crosswalk - the only source that can supply the rule and the agreement flag
#' the triple requires. The BMF's own `ntee_code_raw` is carried through so the
#' recomputation has its input, but the BMF's `nteev2` rendering is deliberately
#' **not** copied: it carries the specialty double-encoding defect
#' (`?md_ntee_canonical`).
#'
#' @section Layer assignment:
#' `bmf_active` means "in the current active BMF release" (§3a), which in this
#' file is `last_vintage_ym` equal to the newest vintage present. Everything else
#' is `bmf_inactive`. `status_code` is carried separately rather than conflated
#' with layer, because status is mutable and layer is provenance (§4).
#'
#' @param version The pinned `bmf_unified` version, e.g. `"v2026-08-11"`.
#' @param con A connection from [md_db()]. Opened and closed here if `NULL`.
#' @param validate Run [md_validate()] on each table and stop on failure.
#' @return A named list of row counts, invisibly.
#' @export
md_ingest_bmf <- function(version, con = NULL, validate = TRUE) {
  pin <- md_source_read_pin("bmf_unified", version)
  if (is.null(pin)) {
    stop("bmf_unified/", version, " is not pinned. Fetch and md_source_pin() it ",
         "first - an unpinned source cannot be traced back to.", call. = FALSE)
  }
  src <- md_path("sources", "bmf_unified", version, pin$local_file)
  if (!file.exists(src)) stop("pinned file is missing: ", src, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }

  vintage <- paste0("bmf_unified-", version)
  P <- function(sql) DBI::dbExecute(con, sprintf(sql, src, vintage))
  msg <- function(...) message(sprintf(...))

  DBI::dbExecute(con, sprintf(
    "CREATE OR REPLACE VIEW bmf_src AS SELECT * FROM read_parquet('%s')", src))
  newest <- DBI::dbGetQuery(con, "SELECT max(last_vintage_ym) AS v FROM bmf_src")$v

  msg("bmf_unified %s - newest vintage in file: %s", version, newest)

  ## ---- entity ---------------------------------------------------------------
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE entity AS
    SELECT
      EIN2                                   AS ein,
      CASE WHEN last_vintage_ym = '%s' THEN 'bmf_active' ELSE 'bmf_inactive' END AS layer,
      (last_vintage_ym = '%s')               AS active,
      first_vintage_ym                       AS first_vintage,
      last_vintage_ym                        AS last_vintage,
      TRY_CAST(bmf_vintages_observed AS INTEGER) AS n_vintages,
      ruling_date,
      bmf_source,
      status_code,
      subsection_code                        AS subsection,
      foundation_code,
      affiliation_code,
      group_exemption_number,
      group_exemption_is_member,
      ntee_code_raw,
      -- resolved-attribute triples, filled by md_ingest_ntee() from the
      -- canonical crosswalk. Present from the start so nothing downstream has
      -- to branch on whether the column exists.
      CAST(NULL AS VARCHAR) AS ntee_code,
      CAST(NULL AS VARCHAR) AS ntee_rule,
      CAST(NULL AS VARCHAR) AS ntee_agreement,
      CAST(NULL AS INTEGER) AS ntee_n_distinct,
      CAST(NULL AS VARCHAR) AS ntee_source,
      CAST(NULL AS VARCHAR) AS nteev2,
      '%s'                                   AS source_vintage
    FROM bmf_src", newest, newest, vintage))
  n_entity <- .md_n(con, "entity")
  msg("  entity  %s rows", format(n_entity, big.mark = ","))

  ## ---- name -----------------------------------------------------------------
  # Three variant classes come straight off the BMF row. `legal` uses
  # org_name_raw rather than org_name_join: the database stores what the source
  # wrote, and normalization is a derived column built later (§3).
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE name AS
    WITH v AS (
      SELECT EIN2 AS ein, org_name_raw      AS name_raw, 'legal'      AS variant_class FROM bmf_src
      WHERE org_name_raw IS NOT NULL AND org_name_raw <> ''
      UNION ALL
      SELECT EIN2, dba_name_raw,            'dba'        FROM bmf_src
      WHERE dba_name_raw IS NOT NULL AND dba_name_raw <> ''
      UNION ALL
      SELECT EIN2, in_care_of_name_raw,     'in_care_of' FROM bmf_src
      WHERE in_care_of_name_raw IS NOT NULL AND in_care_of_name_raw <> ''
    )
    SELECT
      row_number() OVER ()      AS name_id,
      ein, name_raw, variant_class,
      'bmf'                     AS source,
      '%s'                      AS source_vintage,
      CAST(NULL AS INTEGER)     AS n_obs,
      CAST(NULL AS INTEGER)     AS n_corroborators
    FROM v", vintage))
  n_name <- .md_n(con, "name")
  msg("  name    %s rows", format(n_name, big.mark = ","))

  ## ---- address --------------------------------------------------------------
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE address AS
    SELECT
      row_number() OVER ()      AS address_id,
      EIN2                      AS ein,
      CAST(NULL AS BIGINT)      AS name_id,
      org_addr_street_raw       AS street_raw,
      org_addr_city_raw         AS city_raw,
      org_addr_state            AS state,
      org_addr_zip5             AS zip5,
      org_addr_zip4             AS zip_plus4,
      'mailing'                 AS variant_class,
      0                         AS spell_rank,
      'bmf'                     AS source,
      '%s'                      AS source_vintage,
      org_addr_is_po_box        AS is_po_box,
      geo_lat AS lat, geo_lon AS lon, geo_county AS county,
      geo_metro_area AS cbsa
    FROM bmf_src
    WHERE org_addr_street_raw IS NOT NULL AND org_addr_street_raw <> ''", vintage))
  n_addr <- .md_n(con, "address")
  msg("  address %s rows", format(n_addr, big.mark = ","))

  DBI::dbExecute(con, "DROP VIEW IF EXISTS bmf_src")

  for (tb in list(c("entity", n_entity), c("name", n_name), c("address", n_addr))) {
    md_record_vintage(con, "bmf_unified", version, tb[1], as.integer(tb[2]),
                      build_note = sprintf("md_ingest_bmf(); active vintage %s", newest))
  }

  counts <- stats::setNames(c(n_entity, n_name, n_addr), c("entity", "name", "address"))
  if (validate) md_validate_bmf(con)
  invisible(counts)
}

#' @rdname md_ingest_bmf
#' @export
md_validate_bmf <- function(con) {
  eins <- DBI::dbGetQuery(con, "SELECT ein FROM entity")$ein

  message("\nentity")
  e <- DBI::dbGetQuery(con, "SELECT ein, layer, source_vintage FROM entity")
  md_validate_report(md_validate(
    e, key = "ein",
    enums = list(layer = c("bmf_active", "bmf_inactive", "filer_only", "irs527")),
    required = c("layer", "source_vintage")))

  message("\nname")
  n <- DBI::dbGetQuery(con, "SELECT name_id, ein, variant_class, source_vintage FROM name")
  md_validate_report(md_validate(
    n, key = "name_id", parent = eins,
    enums = list(variant_class = c("legal", "dba", "division",
                                   "in_care_of", "observed", "former")),
    required = c("variant_class", "source_vintage")))

  message("\naddress")
  a <- DBI::dbGetQuery(con, "SELECT address_id, ein, variant_class, source_vintage FROM address")
  md_validate_report(md_validate(
    a, key = "address_id", parent = eins,
    enums = list(variant_class = c("mailing", "principal", "observed", "historical")),
    required = c("variant_class", "source_vintage")))

  invisible(TRUE)
}

.md_n <- function(con, tb) {
  DBI::dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s", tb))$n
}
