#' Ingest the resolved address crosswalk as historical spells
#'
#' `address_resolved_crosswalk` is the NCCS address history: 11,299,800 rows over
#' 3,687,468 EINs, each row one *spell* an organisation occupied an address, with
#' `spell_rank`, the vintage range it spans, and how many vintages observed it.
#'
#' It supersedes parsing `metadata-addresses`, whose `ORG_ADDRESS_ALL` is a
#' comma-joined string that collides with commas inside street lines
#' (`?md_meta_caveats`). This file has already done that parse.
#'
#' @section Everything here is historical, including spell_rank 0:
#' Every row enters as `variant_class = 'historical'`, and that is a deliberate
#' choice rather than an oversight about rank 0. The crosswalk is an archive of
#' where organisations have been; its most recent spell is not guaranteed to be
#' where they are now, and its `last_vintage` can be years old. The BMF supplies
#' the current mailing address, and letting a stale spell claim `mailing` would
#' put a reference to work matching organisations to addresses they have left.
#'
#' `spell_rank` and `last_vintage` are both carried, so a consumer that wants
#' "most recent spell, still current as of a recent vintage" can express it -
#' but has to say so.
#'
#' @section Two shape facts worth knowing before selecting this:
#' **Street is present on only 61.2% of rows.** The remainder carry city, state
#' and ZIP but no street line. Those are still real geography and still block on
#' ZIP, so they are loaded rather than discarded, but a spec that assumes a
#' street on every historical address will be disappointed on four rows in ten.
#'
#' **This roughly triples the address table.** It is the largest single source in
#' the database. That is the intended shape - the database holds everything and
#' the spec selects (section 5) - but it makes the section 8 row budget a live
#' concern at compile time rather than a theoretical one.
#'
#' @section A parsing hazard, recorded:
#' DuckDB's CSV sniffer mis-detects this file, inferring no quote character, so a
#' street like `"849 ALMAR AVE. STE. C, PMB 217"` splits into fourteen columns
#' against a thirteen-column header and the read fails. The error text suggests
#' `ignore_errors=true`, which would silently drop every row containing a comma
#' in its street - precisely the rows most worth having. The fix is to state the
#' quote character rather than let it be guessed.
#'
#' @param con A connection from [md_db()].
#' @param path Path to the crosswalk CSV.
#' @return Row count, invisibly.
#' @export
md_ingest_address_crosswalk <- function(con = NULL, path = NULL) {
  if (is.null(path)) {
    path <- md_path("sources", "address_crosswalk", "2026-08",
                    "address_resolved_crosswalk.csv")
  }
  if (!file.exists(path)) stop("no address crosswalk at ", path, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- "address_crosswalk-2026-08"
  msg <- function(...) message(sprintf(...))

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE xw_addr AS
    SELECT
      EIN2                                   AS ein,
      TRY_CAST(spell_rank AS INTEGER)        AS spell_rank,
      nullif(trim(street), '')               AS street_raw,
      nullif(trim(city), '')                 AS city_raw,
      upper(nullif(trim(state), ''))         AS state,
      substr(regexp_replace(coalesce(zip5,''),'[^0-9]','','g'),1,5) AS zip5,
      nullif(first_vintage,'')               AS first_vintage,
      nullif(last_vintage,'')                AS last_vintage,
      TRY_CAST(n_vintages AS INTEGER)        AS n_vintages,
      nullif(source,'')                      AS spell_source
    FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, quote='\"', escape='\"')
    WHERE EIN2 IS NOT NULL AND regexp_matches(EIN2, '^EIN-[0-9]{2}-[0-9]{7}$')",
    gsub("\\\\", "/", path)))
  n_raw <- .md_n(con, "xw_addr")
  msg("  %s address spells", format(n_raw, big.mark = ","))

  # Only spells that reference an EIN the database knows. The crosswalk covers
  # the BMF universe, so this should be near-total; reporting the shortfall
  # rather than assuming it is zero is the point.
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE xw_keep AS
    SELECT x.* FROM xw_addr x JOIN entity e USING (ein)")
  n_keep <- .md_n(con, "xw_keep")
  if (n_keep < n_raw) {
    msg("  %s spells reference EINs not in the database and are held back",
        format(n_raw - n_keep, big.mark = ","))
  }

  DBI::dbExecute(con, "DELETE FROM address WHERE source = 'meta_address'")

  base_addr <- DBI::dbGetQuery(con, "SELECT coalesce(max(address_id),0) AS m FROM address")$m
  n_addr <- DBI::dbExecute(con, sprintf("
    INSERT INTO address (address_id, ein, name_id, street_raw, city_raw, state,
                         zip5, variant_class, spell_rank, source, source_vintage,
                         n_obs, first_vintage, last_vintage, n_vintages)
    SELECT %s + row_number() OVER (), ein, NULL, street_raw, city_raw, state,
           zip5, 'historical', spell_rank, 'meta_address', '%s',
           n_vintages, first_vintage, last_vintage, n_vintages
    FROM xw_keep", format(base_addr, scientific = FALSE), vintage))

  shape <- DBI::dbGetQuery(con, "
    SELECT round(100.0 * avg(CASE WHEN street_raw IS NOT NULL THEN 1 ELSE 0 END), 1) AS pct_street,
           count(DISTINCT ein) AS eins,
           max(spell_rank) AS deepest
    FROM xw_keep")
  msg("  %s rows loaded over %s EINs; street present on %s%%; deepest spell %s",
      format(n_addr, big.mark = ","), format(shape$eins, big.mark = ","),
      shape$pct_street, shape$deepest)

  md_record_vintage(con, "address_crosswalk", "2026-08", "address:historical",
                    as.integer(n_addr),
                    build_note = "md_ingest_address_crosswalk()")
  invisible(n_addr)
}
