#' Ingest the unified BMF into entity, name and address
#'
#' Reads the pinned BMF parquet and writes its rows into the three core tables.
#' Idempotent: re-running replaces the BMF's own rows rather than accumulating,
#' and leaves every other source's rows alone, so a newer BMF can be loaded into
#' a database that already holds Schedule I, the return headers and the rest.
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
#' @section Loading into a database that already has other sources:
#' This used to `CREATE OR REPLACE` all three tables, which deleted every other
#' source's rows and made the BMF loadable only as the first step of a fresh
#' build. It now deletes and re-inserts only its own rows, in one transaction:
#'
#' \itemize{
#'   \item `name` and `address`: rows with `source = 'bmf'`.
#'   \item `entity`: rows from any earlier BMF load, plus any row an earlier
#'     ingest wrote for an EIN this file contains. The BMF is the identity spine,
#'     so its row replaces a `filer_only`, `approved_only` or other placeholder
#'     for the same EIN.
#'   \item An EIN that an earlier BMF load had but this file does not, and that
#'     another source's `name`, `address` or `entity_event` row still refers to,
#'     is put back with the layer a fresh build would give it: that of the
#'     earliest-built source still naming it (`approved_only` for 1023-EZ,
#'     `filer_only` for the 990 filings and schedules, `postcard_only`,
#'     `revoked_only`). No row is left pointing at a missing entity.
#' }
#'
#' Replaced rows lose whatever later steps wrote onto them, and the new BMF rows
#' get new `name_id`/`address_id` values. After a re-ingest, re-run the steps
#' that follow the ingests in `dev/build-matchdb.R` (NTEE, geocode, guards,
#' derived columns with `incremental = TRUE`, compaction, groups, keys,
#' clusters, statistics). The ingest prints this reminder when it replaced
#' anything.
#'
#' @param version The pinned `bmf_unified` version, e.g. `"v2026-08-11"`.
#' @param con A connection from [md_db()]. Opened and closed here if `NULL`.
#' @param validate Run [md_validate()] on each table and stop on failure.
#' @return A named vector of the BMF's own row counts, invisibly.
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
  msg <- function(...) message(sprintf(...))

  DBI::dbExecute(con, sprintf(
    "CREATE OR REPLACE TEMP VIEW bmf_src AS SELECT * FROM read_parquet('%s')",
    gsub("\\\\", "/", src)))
  on.exit(DBI::dbExecute(con, "DROP VIEW IF EXISTS bmf_src"), add = TRUE, after = FALSE)
  newest <- DBI::dbGetQuery(con, "SELECT max(last_vintage_ym) AS v FROM bmf_src")$v

  msg("bmf_unified %s - newest vintage in file: %s", version, newest)

  ## ---- the three SELECTs ------------------------------------------------------
  entity_sql <- sprintf("
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
    FROM bmf_src", newest, newest, vintage)

  # Three variant classes come straight off the BMF row. `legal` uses
  # org_name_raw rather than org_name_join: the database stores what the source
  # wrote, and normalization is a derived column built later (§3).
  #
  # Ids are numbered in a fixed order so the same file always gets the same ids
  # relative to `base` (PAIN-POINTS.md: no order-dependent results in an ingest).
  name_sql <- function(base) sprintf("
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
      %s + row_number() OVER (ORDER BY ein, variant_class, name_raw) AS name_id,
      ein, name_raw, variant_class,
      'bmf'                     AS source,
      '%s'                      AS source_vintage,
      CAST(NULL AS INTEGER)     AS n_obs,
      CAST(NULL AS INTEGER)     AS n_corroborators,
      -- every later ingest inserts these; without them a fresh build fails at
      -- the first one (the return headers)
      CAST(NULL AS INTEGER)     AS first_year,
      CAST(NULL AS INTEGER)     AS last_year
    FROM v", format(base, scientific = FALSE), vintage)

  address_sql <- function(base) sprintf("
    SELECT
      %s + row_number() OVER (ORDER BY EIN2) AS address_id,
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
      CAST(NULL AS INTEGER)     AS n_obs,
      CAST(NULL AS INTEGER)     AS n_corroborators,
      first_vintage_ym          AS first_vintage,
      last_vintage_ym           AS last_vintage,
      TRY_CAST(bmf_vintages_observed AS INTEGER) AS n_vintages,
      org_addr_is_po_box        AS is_po_box,
      geo_lat AS lat, geo_lon AS lon, geo_county AS county,
      geo_metro_area AS cbsa
    FROM bmf_src
    -- a place without a street (city, state or ZIP only) is still a place: the
    -- pfmatch reference keeps it, and a ZIP alone still blocks and scores
    WHERE coalesce(trim(org_addr_street_raw), '') <> '' OR coalesce(trim(org_addr_city_raw), '') <> ''
       OR coalesce(trim(org_addr_state), '') <> '' OR coalesce(trim(org_addr_zip5), '') <> ''",
    format(base, scientific = FALSE), vintage)

  ## ---- write: delete our own rows, insert the new ones ------------------------
  # One transaction, so a failure part-way cannot leave the BMF's names deleted
  # and its new ones not yet written.
  replaced <- c(entity = 0, name = 0, address = 0)
  superseded <- 0; restored <- 0
  is_bmf_entity <- "starts_with(coalesce(source_vintage, ''), 'bmf_unified-')"

  DBI::dbWithTransaction(con, {
    ## entity
    if (!DBI::dbExistsTable(con, "entity")) {
      DBI::dbExecute(con, paste("CREATE TABLE entity AS", entity_sql))
    } else {
      replaced["entity"] <- DBI::dbGetQuery(con, sprintf(
        "SELECT count(*) AS n FROM entity WHERE %s", is_bmf_entity))$n
      superseded <- DBI::dbGetQuery(con, sprintf(
        "SELECT count(*) AS n FROM entity
         WHERE NOT %s AND ein IN (SELECT EIN2 FROM bmf_src)", is_bmf_entity))$n
      DBI::dbExecute(con, sprintf(
        "DELETE FROM entity WHERE %s OR ein IN (SELECT EIN2 FROM bmf_src)",
        is_bmf_entity))
      DBI::dbExecute(con, paste("INSERT INTO entity BY NAME", entity_sql))
    }

    ## name
    if (!DBI::dbExistsTable(con, "name")) {
      DBI::dbExecute(con, paste("CREATE TABLE name AS", name_sql(0)))
    } else {
      replaced["name"] <- DBI::dbExecute(con, "DELETE FROM name WHERE source = 'bmf'")
      base <- DBI::dbGetQuery(con, "SELECT coalesce(max(name_id), 0) AS m FROM name")$m
      DBI::dbExecute(con, paste("INSERT INTO name BY NAME", name_sql(base)))
    }

    ## address
    if (!DBI::dbExistsTable(con, "address")) {
      DBI::dbExecute(con, paste("CREATE TABLE address AS", address_sql(0)))
    } else {
      replaced["address"] <- DBI::dbExecute(con, "DELETE FROM address WHERE source = 'bmf'")
      base <- DBI::dbGetQuery(con, "SELECT coalesce(max(address_id), 0) AS m FROM address")$m
      DBI::dbExecute(con, paste("INSERT INTO address BY NAME", address_sql(base)))
    }

    ## EINs an earlier BMF had, this one does not, and another source still uses.
    restored <- .md_restore_unlisted_entities(con)

    n_entity <- DBI::dbGetQuery(con, sprintf(
      "SELECT count(*) AS n FROM entity WHERE source_vintage = '%s'", vintage))$n
    n_name <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM name WHERE source = 'bmf'")$n
    n_addr <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM address WHERE source = 'bmf'")$n

    for (tb in list(c("entity", n_entity), c("name", n_name), c("address", n_addr))) {
      md_record_vintage(con, "bmf_unified", version, tb[1], as.integer(tb[2]),
                        build_note = sprintf("md_ingest_bmf(); active vintage %s", newest),
                        content_vintage = newest, content_vintage_rule = "measured")
    }
  })

  msg("  entity  %s rows", format(n_entity, big.mark = ","))
  msg("  name    %s rows", format(n_name, big.mark = ","))
  msg("  address %s rows", format(n_addr, big.mark = ","))

  if (sum(replaced) + superseded + restored > 0) {
    msg("  replaced earlier BMF rows: %s entity, %s name, %s address",
        format(replaced[["entity"]], big.mark = ","),
        format(replaced[["name"]], big.mark = ","),
        format(replaced[["address"]], big.mark = ","))
    if (superseded > 0) {
      msg("  %s filer_only placeholder(s) replaced by their BMF row",
          format(superseded, big.mark = ","))
    }
    if (restored > 0) {
      msg("  %s EIN(s) no longer in the BMF kept as filer_only - other sources refer to them",
          format(restored, big.mark = ","))
    }
    msg(paste("  replaced rows lost later enrichment and have new ids. Re-run the",
              "steps after the ingests in dev/build-matchdb.R: NTEE, geocode, guards,",
              "derived columns (incremental = TRUE), compaction, groups, keys,",
              "clusters, statistics"))
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
    enums = list(layer = md_layers()),
    required = c("layer", "source_vintage")))

  message("\nname")
  n <- DBI::dbGetQuery(con, "SELECT name_id, ein, variant_class, source_vintage FROM name")
  md_validate_report(md_validate(
    n, key = "name_id", parent = eins,
    enums = list(variant_class = md_name_classes()),
    required = c("variant_class", "source_vintage")))

  message("\naddress")
  a <- DBI::dbGetQuery(con, "SELECT address_id, ein, variant_class, source_vintage FROM address")
  md_validate_report(md_validate(
    a, key = "address_id", parent = eins,
    enums = list(variant_class = md_address_classes()),
    required = c("variant_class", "source_vintage")))

  invisible(TRUE)
}

# The layer each ingest gives an EIN it admits that no BMF lists, in the order
# dev/build-matchdb.R runs them. The first ingest to see an EIN sets its layer,
# so an EIN put back after leaving the BMF takes the layer of the earliest-built
# source that still refers to it - the layer a fresh build would give it.
# A source not listed here falls back to filer_only, after the listed ones.
.md_admit_layers <- data.frame(
  source = c("f1023ez", "efile990", "schedi", "schedr", "e_postcard", "revocations"),
  layer  = c("approved_only", "filer_only", "filer_only", "filer_only",
             "postcard_only", "revoked_only"),
  rk     = c(1L, 2L, 2L, 2L, 3L, 4L),
  stringsAsFactors = FALSE)

# Put back every EIN that some name, address or event row refers to but entity
# no longer has, so no row points at a missing entity. Returns the count.
.md_restore_unlisted_entities <- function(con) {
  refs <- c("SELECT ein, source, source_vintage FROM name",
            "SELECT ein, source, source_vintage FROM address")
  if (DBI::dbExistsTable(con, "entity_event")) {
    refs <- c(refs, "SELECT ein, source, source_vintage FROM entity_event")
  }
  m <- .md_admit_layers
  case <- function(col, default) sprintf("CASE r.source %s ELSE %s END",
    paste(sprintf("WHEN '%s' THEN %s", m$source,
                  if (col == "layer") sprintf("'%s'", m$layer) else m$rk),
          collapse = " "), default)
  DBI::dbExecute(con, sprintf("
    INSERT INTO entity (ein, layer, active, source_vintage)
    SELECT ein, layer, FALSE, source_vintage FROM (
      SELECT r.ein, r.source_vintage, %s AS layer,
             row_number() OVER (PARTITION BY r.ein
                                ORDER BY %s, r.source_vintage) AS pick
      FROM (%s) r
      WHERE r.ein NOT IN (SELECT ein FROM entity)
    ) WHERE pick = 1",
    case("layer", "'filer_only'"), case("rk", "99"),
    paste(refs, collapse = " UNION ALL ")))
}

.md_n <- function(con, tb) {
  DBI::dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s", tb))$n
}
