#' Ingest Schedule R related organisations as observed names and addresses
#'
#' The same files [md_ingest_relations()] reads for its affiliate pairs also
#' carry the related organisation's **name and address**, written by the filer.
#' That makes Schedule R Part II a second `(name, address) -> EIN` source of the
#' same kind as Schedule I, and reading only the EIN pair discards it.
#'
#' @section How this differs from Schedule I:
#' Both are third parties writing about an EIN, so both are `observed` (section
#' 3a). The expectation going in was that Schedule R would be the weaker of the
#' two on corroboration - a related organisation is disclosed only by its own
#' affiliates, of which there might be one or two, where a Schedule I recipient
#' is written about by whoever happened to fund it.
#'
#' **Measured, that is wrong, and in the useful direction.** Schedule R is the
#' better corroborated source of the pair:
#'
#' \preformatted{
#'   distinct filers    schedi          schedr
#'   1                  1,339,769 77.8%   124,272 66.6%
#'   2-4                  276,766 16.1%    35,084 18.8%
#'   5-19                  95,735  5.6%    17,584  9.4%
#'   20+                   10,534  0.6%     9,523  5.1%
#' }
#'
#' Fewer single-filer rows, and eight times the share at twenty or more. Group
#' structure is why: a national organisation with hundreds of chapters is
#' disclosed by every one of them, so the very entities most likely to be
#' confused with their affiliates are the ones carrying the most corroboration.
#'
#' The practical consequence is the opposite of what was assumed - a shared
#' `min_corroborators` floor costs *less* here than on Schedule I, not more.
#'
#' @section The near-identical-name hazard:
#' Schedule R names are systematically related to the filer's, since an
#' organisation and its supporting foundation usually share a stem. That is
#' exactly the condition section 10 warns produces false matches.
#'
#' What makes it safe is that every row carries the **disclosed** EIN. The name
#' attaches to the organisation it names rather than to the filer, which is the
#' difference between recording an affiliate's name as an alias of itself - fine,
#' and the point - and as an alias of its parent, which section 10 forbids.
#'
#' @param version Pinned `efile_related` version.
#' @param con A connection from [md_db()].
#' @param min_corroborators Minimum distinct filers. Defaults to 1; see above for
#'   how corroboration actually distributes here.
#' @return Row counts, invisibly.
#' @export
md_ingest_schedr <- function(version = "v2_2", con = NULL, min_corroborators = 1L) {
  dir <- md_path("sources", "efile_related", version)
  files <- list.files(dir, pattern = "^SR-P02-T01-.*[.]CSV$", full.names = TRUE)
  if (!length(files)) stop("no Schedule R files in ", dir, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- paste0("efile_related-", version)
  msg <- function(...) message(sprintf(...))
  msg("schedule R: %d year files", length(files))

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE sr_clean AS
    SELECT
      'EIN-' || substr(d,1,2) || '-' || substr(d,3,9) AS ein,
      filer_ein, tax_year, name_raw, street_raw, city_raw, state, zip5,
      trim(regexp_replace(regexp_replace(upper(name_raw),'[^A-Z0-9 ]','','g'),
                          ' +',' ','g')) AS name_key
    FROM (
      SELECT
        EIN2 AS filer_ein,
        TRY_CAST(TAX_YEAR AS INTEGER) AS tax_year,
        trim(coalesce(SR_02_RLTD_ORG_NAME_L1,'') || ' ' ||
             coalesce(SR_02_RLTD_ORG_NAME_L2,''))   AS name_raw,
        trim(coalesce(SR_02_RLTD_ORG_ADDR_L1,'') || ' ' ||
             coalesce(SR_02_RLTD_ORG_ADDR_L2,''))   AS street_raw,
        trim(coalesce(SR_02_RLTD_ORG_ADDR_CITY,'')) AS city_raw,
        upper(trim(coalesce(SR_02_RLTD_ORG_ADDR_STATE,''))) AS state,
        substr(regexp_replace(coalesce(SR_02_RLTD_ORG_ADDR_ZIP,''),'[^0-9]','','g'),1,5) AS zip5,
        lpad(regexp_replace(coalesce(SR_02_RLTD_ORG_EIN,''),'[^0-9]','','g'),9,'0') AS d
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE,
                         quote='\"', escape='\"')
      WHERE length(regexp_replace(coalesce(SR_02_RLTD_ORG_EIN,''),'[^0-9]','','g')) BETWEEN 1 AND 9
    )
    WHERE name_raw <> ''", file.path(dir, "SR-P02-T01-*.CSV")))
  n_raw <- .md_n(con, "sr_clean")
  msg("  %s disclosures with a usable EIN and name", format(n_raw, big.mark = ","))

  DBI::dbExecute(con, "DELETE FROM address WHERE source = 'schedr'")
  DBI::dbExecute(con, "DELETE FROM name WHERE source = 'schedr'")

  ## ---- new entities -----------------------------------------------------------
  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO entity (ein, layer, active, source_vintage)
    SELECT DISTINCT s.ein, 'filer_only', FALSE, '%s'
    FROM sr_clean s LEFT JOIN entity e USING (ein)
    WHERE e.ein IS NULL", vintage))
  msg("  %s related EINs new to the database (layer = filer_only)",
      format(n_new, big.mark = ","))

  ## ---- names ------------------------------------------------------------------
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE sr_alias AS
    WITH agg AS (
      SELECT ein, name_key,
             count(*)                  AS n_obs,
             count(DISTINCT filer_ein) AS n_corroborators,
             min(tax_year) AS first_year, max(tax_year) AS last_year
      FROM sr_clean WHERE trim(name_key) <> ''
      GROUP BY 1,2 HAVING count(DISTINCT filer_ein) >= %d
    ), %s
    SELECT a.*, s.name_raw
    FROM agg a JOIN modal_name_raw s USING (ein, name_key)
    WHERE s.rk = 1", as.integer(min_corroborators),
    md_modal_sql("sr_clean", c("ein", "name_key"), "name_raw",
                 where = "trim(name_key) <> ''")))
  n_alias <- .md_n(con, "sr_alias")

  base_name <- DBI::dbGetQuery(con, "SELECT coalesce(max(name_id),0) AS m FROM name")$m
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE sr_name AS
    SELECT %s + row_number() OVER () AS name_id, * FROM sr_alias",
    format(base_name, scientific = FALSE)))
  DBI::dbExecute(con, sprintf("
    INSERT INTO name (name_id, ein, name_raw, variant_class, source,
                      source_vintage, n_obs, n_corroborators, first_year, last_year)
    SELECT name_id, ein, name_raw, 'observed', 'schedr', '%s', n_obs, n_corroborators,
           first_year, last_year
    FROM sr_name", vintage))
  msg("  %s observed names", format(n_alias, big.mark = ","))

  ## ---- addresses, carrying the pairing link ------------------------------------
  place_by <- c("ein", "name_key", "city_key", "state_key", "zip5")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE sr_place AS
    WITH k AS (
      SELECT *, upper(trim(coalesce(city_raw,''))) AS city_key,
                upper(trim(coalesce(state,'')))    AS state_key
      FROM sr_clean WHERE trim(name_key) <> ''
    ), agg AS (
      SELECT ein, name_key, city_key, state_key, zip5, count(*) AS n_obs
      FROM k GROUP BY 1,2,3,4,5
    ), %s, %s
    SELECT a.ein, a.name_key, a.city_key, a.state_key, a.zip5,
           st.street_raw, ct.city_raw, a.n_obs
    FROM agg a
    JOIN modal_street_raw st USING (ein, name_key, city_key, state_key, zip5)
    JOIN modal_city_raw   ct USING (ein, name_key, city_key, state_key, zip5)
    WHERE st.rk = 1 AND ct.rk = 1",
    md_modal_sql("k", place_by, "street_raw"),
    md_modal_sql("k", place_by, "city_raw")))

  base_addr <- DBI::dbGetQuery(con, "SELECT coalesce(max(address_id),0) AS m FROM address")$m
  n_addr <- DBI::dbExecute(con, sprintf("
    INSERT INTO address (address_id, ein, name_id, street_raw, city_raw, state,
                         zip5, variant_class, spell_rank, source, source_vintage,
                         n_obs)
    SELECT %s + row_number() OVER (), p.ein, n.name_id, p.street_raw, p.city_raw,
           p.state_key, p.zip5, 'observed', 0, 'schedr', '%s', p.n_obs
    FROM sr_place p JOIN sr_name n USING (ein, name_key)
    WHERE coalesce(p.street_raw,'') <> '' OR coalesce(p.city_raw,'') <> ''",
    format(base_addr, scientific = FALSE), vintage))
  msg("  %s observed addresses", format(n_addr, big.mark = ","))

  bands <- DBI::dbGetQuery(con, "
    SELECT CASE WHEN n_corroborators = 1 THEN '1 filer'
                WHEN n_corroborators < 5 THEN '2-4'
                WHEN n_corroborators < 20 THEN '5-19' ELSE '20+' END AS band,
           count(*) AS n
    FROM sr_alias GROUP BY 1 ORDER BY min(n_corroborators)")
  msg("  corroboration: %s",
      paste(sprintf("%s %s", bands$band, format(bands$n, big.mark = ",")),
            collapse = ", "))

  for (tb in list(c("name:observed", n_alias), c("address:observed", n_addr),
                  c("entity:filer_only", n_new))) {
    md_record_vintage(con, "efile_related", version, paste0("schedr:", tb[1]),
                      as.integer(tb[2]),
                      build_note = sprintf("md_ingest_schedr(min_corroborators=%d)",
                                           as.integer(min_corroborators)))
  }
  invisible(stats::setNames(c(n_alias, n_addr, n_new),
                            c("names", "addresses", "new_entities")))
}
