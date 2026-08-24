#' Ingest the 990 filing header as self-reported names and addresses
#'
#' `F9-P00-T00-HEADER` is one row per Form 990 filing, 2009-2024, carrying the
#' organisation's own name, DBA, in-care-of line and mailing address **as it
#' wrote them on that year's return**.
#'
#' @section What makes this different from the BMF:
#' The BMF holds one current name per EIN. This holds one per filing year, so it
#' is the first source here that can show a name *changing*. That is what makes
#' `variant_class = 'former'` derivable rather than aspirational: within an EIN,
#' the spelling carried by the most recent filing is `legal` and every earlier
#' distinct spelling is `former`, which is exactly the definition in section 3a.
#'
#' @section What is deliberately not ingested:
#' `F9_00_PRIN_OFF_*` looks like a principal *office* address and is not - it is
#' the principal **officer**, as the neighbouring `F9_00_PRIN_OFF_NAME_PERS`
#' makes plain. Those rows are a natural person's name and address, and where the
#' officer is an organisation it is a *different* organisation from the filer, so
#' attaching its address to the filer's EIN would be wrong on top of intrusive.
#'
#' A consequence worth stating: `address.variant_class = 'principal'` stays empty
#' after this ingest. The 990 header does not publish a principal-office address
#' distinct from the mailing address, and an empty class is a more honest answer
#' than one filled with somebody's home address.
#'
#' @param version Pinned `efile_header` version, e.g. `"v2_2"`.
#' @param con A connection from [md_db()].
#' @return Row counts, invisibly.
#' @export
md_ingest_efile_header <- function(version = "v2_2", con = NULL) {
  dir <- md_path("sources", "efile_header", version)
  files <- list.files(dir, pattern = "^F9-P00-T00-HEADER-[0-9]{4}[.]CSV$",
                      full.names = TRUE)
  if (!length(files)) stop("no header files in ", dir, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- paste0("efile_header-", version)
  msg <- function(...) message(sprintf(...))
  msg("efile header: %d year files", length(files))

  glob <- file.path(dir, "F9-P00-T00-HEADER-*.CSV")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE hdr AS
    SELECT
      EIN2 AS ein,
      TRY_CAST(TAX_YEAR AS INTEGER) AS tax_year,
      trim(coalesce(F9_00_ORG_NAME_L1, ORG_NAME_L1, '') || ' ' ||
           coalesce(F9_00_ORG_NAME_L2, ORG_NAME_L2, ''))        AS name_legal,
      trim(coalesce(F9_00_ORG_NAME_DBA_L1,'') || ' ' ||
           coalesce(F9_00_ORG_NAME_DBA_L2,''))                  AS name_dba,
      trim(coalesce(F9_00_ORG_ADDR_IN_CARE_OF,''))              AS name_ico,
      trim(coalesce(F9_00_ORG_ADDR_L1,''))                      AS street_raw,
      trim(coalesce(F9_00_ORG_ADDR_CITY,''))                    AS city_raw,
      upper(trim(coalesce(F9_00_ORG_ADDR_STATE,'')))            AS state,
      substr(regexp_replace(coalesce(F9_00_ORG_ADDR_ZIP,''),'[^0-9]','','g'),1,5) AS zip5
    FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE)
    WHERE EIN2 IS NOT NULL AND regexp_matches(EIN2, '^EIN-[0-9]{2}-[0-9]{7}$')",
    glob))
  n_filings <- .md_n(con, "hdr")
  msg("  %s filings", format(n_filings, big.mark = ","))

  # Idempotence: a full load keyed on source_vintage (section 10).
  DBI::dbExecute(con, "DELETE FROM address WHERE source = 'efile990'")
  DBI::dbExecute(con, "DELETE FROM name WHERE source = 'efile990'")

  ## ---- entities ---------------------------------------------------------------
  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO entity (ein, layer, active, source_vintage)
    SELECT DISTINCT h.ein, 'filer_only', FALSE, '%s'
    FROM hdr h LEFT JOIN entity e USING (ein) WHERE e.ein IS NULL", vintage))
  msg("  %s filer EINs new to the database (layer = filer_only)",
      format(n_new, big.mark = ","))

  ## ---- names ------------------------------------------------------------------
  # One row per (ein, class, normalised spelling), with the years it spans.
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE hdr_long AS
    SELECT ein, tax_year, 'legal' AS variant_class, name_legal AS name_raw FROM hdr WHERE name_legal <> ''
    UNION ALL
    SELECT ein, tax_year, 'dba',        name_dba FROM hdr WHERE name_dba <> ''
    UNION ALL
    SELECT ein, tax_year, 'in_care_of', name_ico FROM hdr WHERE name_ico <> ''")
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE hdr_key AS
    SELECT *, trim(regexp_replace(regexp_replace(upper(name_raw),'[^A-Z0-9 ]','','g'),
                                  ' +',' ','g')) AS name_key
    FROM hdr_long")

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE hdr_name AS
    WITH agg AS (
      SELECT ein, variant_class, name_key,
             count(*) AS n_obs, min(tax_year) AS first_year, max(tax_year) AS last_year
      FROM hdr_key WHERE name_key <> '' GROUP BY 1,2,3
    ), %s
    SELECT a.*, s.name_raw
    FROM agg a JOIN modal_name_raw s USING (ein, variant_class, name_key)
    WHERE s.rk = 1",
    md_modal_sql("hdr_key", c("ein", "variant_class", "name_key"), "name_raw",
                 where = "name_key <> ''")))

  # A legal name superseded by a later one is `former` (section 3a). Ties on
  # last_year keep every tied spelling as legal rather than picking arbitrarily:
  # an organisation really can file two spellings in its final year, and guessing
  # between them would invent a fact.
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE hdr_name2 AS
    SELECT n.*,
           CASE WHEN n.variant_class = 'legal'
                 AND n.last_year < max(CASE WHEN n.variant_class = 'legal'
                                            THEN n.last_year END)
                                     OVER (PARTITION BY n.ein)
                THEN 'former' ELSE n.variant_class END AS final_class
    FROM hdr_name n")

  base_name <- DBI::dbGetQuery(con, "SELECT coalesce(max(name_id),0) AS m FROM name")$m
  n_name <- DBI::dbExecute(con, sprintf("
    INSERT INTO name (name_id, ein, name_raw, variant_class, source,
                      source_vintage, n_obs, n_corroborators, first_year, last_year)
    SELECT %s + row_number() OVER (), ein, name_raw, final_class, 'efile990', '%s',
           n_obs, NULL, first_year, last_year
    FROM hdr_name2", format(base_name, scientific = FALSE), vintage))

  shape <- DBI::dbGetQuery(con, "SELECT final_class, count(*) n FROM hdr_name2 GROUP BY 1 ORDER BY n DESC")
  msg("  %s names: %s", format(n_name, big.mark = ","),
      paste(sprintf("%s %s", shape$final_class, format(shape$n, big.mark = ",")),
            collapse = ", "))

  ## ---- addresses ---------------------------------------------------------------
  # spell_rank 0 is the most recent filing's address, ascending into the past, so
  # a consumer can take the current one without knowing the year range.
  base_addr <- DBI::dbGetQuery(con, "SELECT coalesce(max(address_id),0) AS m FROM address")$m
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE hdr_addr AS
    WITH agg AS (
      SELECT ein, street_key, city_key, state, zip5,
             count(*) AS n_obs, min(tax_year) AS first_year, max(tax_year) AS last_year
      FROM (SELECT *, upper(street_raw) AS street_key, upper(city_raw) AS city_key
            FROM hdr WHERE street_raw <> '')
      GROUP BY 1,2,3,4,5
    ), %s, %s
    SELECT a.*, st.street_raw, ct.city_raw,
           row_number() OVER (PARTITION BY a.ein
                              ORDER BY a.last_year DESC, a.n_obs DESC,
                                       a.street_key ASC) - 1 AS spell_rank
    FROM agg a
    JOIN modal_street_raw st USING (ein, street_key, city_key, state, zip5)
    JOIN modal_city_raw   ct USING (ein, street_key, city_key, state, zip5)
    WHERE st.rk = 1 AND ct.rk = 1",
    md_modal_sql("(SELECT *, upper(street_raw) AS street_key, upper(city_raw) AS city_key
                   FROM hdr WHERE street_raw <> '')",
                 c("ein", "street_key", "city_key", "state", "zip5"), "street_raw"),
    md_modal_sql("(SELECT *, upper(street_raw) AS street_key, upper(city_raw) AS city_key
                   FROM hdr WHERE street_raw <> '')",
                 c("ein", "street_key", "city_key", "state", "zip5"), "city_raw")))

  n_addr <- DBI::dbExecute(con, sprintf("
    INSERT INTO address (address_id, ein, name_id, street_raw, city_raw, state,
                         zip5, variant_class, spell_rank, source, source_vintage,
                         n_obs)
    SELECT %s + row_number() OVER (), ein, NULL, street_raw, city_raw, state, zip5,
           CASE WHEN spell_rank = 0 THEN 'mailing' ELSE 'historical' END,
           spell_rank, 'efile990', '%s', n_obs
    FROM hdr_addr", format(base_addr, scientific = FALSE), vintage))
  msg("  %s addresses", format(n_addr, big.mark = ","))

  for (tb in list(c("name:efile990", n_name), c("address:efile990", n_addr),
                  c("entity:filer_only", n_new))) {
    md_record_vintage(con, "efile_header", version, tb[1], as.integer(tb[2]),
                      build_note = "md_ingest_efile_header()")
  }
  invisible(stats::setNames(c(n_name, n_addr, n_new),
                            c("names", "addresses", "new_entities")))
}
