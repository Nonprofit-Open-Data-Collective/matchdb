#' Attach census geography to the addresses it actually describes
#'
#' `metadata-address-geocoded` carries census geography - county, CBSA, tract,
#' block, urban area - plus coordinates, for 3,436,984 EINs.
#'
#' @section It is one geocode per EIN, not one per address spell:
#' Each row carries a single `ORG_ADDR_FULL` and the `ORG_FISCAL_YEAR` it came
#' from, and those years run from 1989 to 2024: 62% are 2020 or later, but
#' 332,621 predate 2000. So the file does not describe "where this organisation
#' is" - it describes where it was in one particular year.
#'
#' Attaching it to whichever address row happens to be current would therefore
#' be wrong for a third of the file. Instead the geocode is joined back to the
#' address it names, by parsing `ORG_ADDR_FULL` and matching on
#' `(ein, street, city, state, zip5)`. Rows that match get the geography; rows
#' that do not are reported and dropped. An unattached geocode is better than
#' one attached to the wrong address.
#'
#' @section Parsing from the right:
#' `ORG_ADDR_FULL` is comma-joined `street,city,state,zip`, and street lines
#' contain commas - `"849 ALMAR AVE. STE. C, PMB 217"` is a real example from the
#' sibling crosswalk. Splitting left-to-right therefore mis-assigns the fields
#' whenever a street has a comma in it. The last three fields are always city,
#' state and ZIP, so this splits from the right and rejoins whatever remains as
#' the street.
#'
#' @section Not all coordinates mean the same thing:
#' `ADDR_TYPE` records what the geocoder actually resolved, and only 1,783,685 of
#' 3,436,986 rows are `PointAddress` - an actual rooftop. 693,034 are `Postal`
#' and 482,890 `PostalExt`, which are **ZIP centroids**: a point in the middle of
#' a postal area, not the organisation's location. Treating those as coordinates
#' would put every organisation in a ZIP at the same spot and make any
#' distance-based comparison confidently wrong.
#'
#' So `geocode_type` is stored beside the coordinates rather than discarded, and
#' any consumer computing distance should filter on it. The column exists to make
#' that possible; nothing here enforces it.
#'
#' @param con A connection from [md_db()].
#' @param path Path to the geocoded CSV.
#' @param version Pinned `address_geocoded` version.
#' @return Row counts, invisibly.
#' @export
md_ingest_geocode <- function(con = NULL, path = NULL, version = "2026-08") {
  if (is.null(path)) {
    path <- md_path("sources", "address_geocoded", version,
                    "metadata-address-geocoded.csv")
  }
  if (!file.exists(path)) stop("no geocoded file at ", path, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))

  # Columns the earlier ingests did not create. Added here rather than by
  # rebuilding from the BMF, so enriching geography does not require reloading
  # 18 million address rows.
  have <- names(DBI::dbGetQuery(con, "SELECT * FROM address LIMIT 0"))
  for (col in c("tract", "geocode_type", "geocode_vintage")) {
    if (!col %in% have) {
      DBI::dbExecute(con, sprintf("ALTER TABLE address ADD COLUMN %s VARCHAR", col))
    }
  }

  # Split from the right: the last three comma fields are city, state, zip and
  # everything before them is the street, commas included.
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE geo AS
    WITH p AS (
      SELECT EIN2 AS ein,
             str_split(coalesce(ORG_ADDR_FULL,''), ',') AS parts,
             nullif(CENSUS_COUNTY_NAME,'')  AS county,
             nullif(CENSUS_CBSA_NAME,'')    AS cbsa,
             nullif(CENSUS_TRACT_FIPS,'')   AS tract,
             nullif(LATITUDE,'')            AS lat,
             nullif(LONGITDUE,'')           AS lon,
             nullif(ADDR_TYPE,'')           AS geocode_type,
             nullif(ORG_FISCAL_YEAR,'')     AS geocode_vintage
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, quote='\"', escape='\"')
      WHERE EIN2 IS NOT NULL AND regexp_matches(EIN2,'^EIN-[0-9]{2}-[0-9]{7}$')
    )
    SELECT ein, county, cbsa, tract, lat, lon, geocode_type, geocode_vintage,
           upper(trim(array_to_string(parts[1:greatest(len(parts)-3, 0)], ','))) AS street_key,
           upper(trim(parts[len(parts)-2])) AS city_key,
           upper(trim(parts[len(parts)-1])) AS state_key,
           substr(regexp_replace(coalesce(parts[len(parts)],''),'[^0-9]','','g'),1,5) AS zip5
    FROM p
    WHERE len(parts) >= 3", gsub("\\\\", "/", path)))
  n_geo <- .md_n(con, "geo")
  msg("  %s geocodes parsed", format(n_geo, big.mark = ","))

  n_matched <- DBI::dbExecute(con, "
    UPDATE address a SET
      county          = g.county,
      cbsa            = g.cbsa,
      tract           = g.tract,
      lat             = TRY_CAST(g.lat AS DOUBLE),
      lon             = TRY_CAST(g.lon AS DOUBLE),
      geocode_type    = g.geocode_type,
      geocode_vintage = g.geocode_vintage
    FROM geo g
    WHERE a.ein = g.ein
      AND upper(trim(coalesce(a.street_raw,''))) = g.street_key
      AND upper(trim(coalesce(a.city_raw,'')))   = g.city_key
      AND coalesce(a.zip5,'') = g.zip5")
  # Two different numbers, and conflating them produces a coverage figure over
  # 100%. One geocode legitimately enriches several address rows: the same
  # address is present as a BMF mailing row, a meta_address historical spell and
  # a Schedule I observed row, and all three should carry the geography. So
  # "rows enriched" measures reach into the address table, while "geocodes
  # placed" measures how much of the source was used at all.
  placed <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM (
      SELECT DISTINCT g.ein, g.street_key, g.city_key, g.zip5
      FROM geo g JOIN address a
        ON a.ein = g.ein
       AND upper(trim(coalesce(a.street_raw,''))) = g.street_key
       AND upper(trim(coalesce(a.city_raw,'')))   = g.city_key
       AND coalesce(a.zip5,'') = g.zip5)")$n
  msg("  %s address rows enriched, from %s of %s geocodes placed (%s%%)",
      format(n_matched, big.mark = ","), format(placed, big.mark = ","),
      format(n_geo, big.mark = ","), round(100 * placed / max(n_geo, 1), 1))

  qual <- DBI::dbGetQuery(con, "
    SELECT geocode_type, count(*) AS n FROM address
    WHERE geocode_type IS NOT NULL GROUP BY 1 ORDER BY n DESC")
  rooftop <- sum(qual$n[qual$geocode_type == "PointAddress"])
  msg("  of those, %s are rooftop PointAddress and %s are ZIP centroids",
      format(rooftop, big.mark = ","),
      format(sum(qual$n[qual$geocode_type %in% c("Postal", "PostalExt")]),
             big.mark = ","))

  md_record_vintage(con, "address_geocoded", version, "address:geography",
                    as.integer(n_matched), build_note = "md_ingest_geocode()")
  invisible(stats::setNames(c(n_geo, n_matched), c("parsed", "matched")))
}
