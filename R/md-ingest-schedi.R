#' Ingest Schedule I recipient aliases as observed names and addresses
#'
#' Form 990 Schedule I Part II is where a non-PF filer lists every grant it made
#' to a US organisation, with the recipient's **name, address and EIN**. That
#' last field is what makes it unlike every other source here: it is a large set
#' of (name variant, address variant) to EIN observations, written by third
#' parties, in the register a grantmaker actually uses.
#'
#' The BMF gives one legal name per EIN. This gives many *observed* names, and
#' it is the source `pfmatch/dev/AUDIT-FINDINGS.md` named as the missing piece
#' for brand-versus-legal-name matching.
#'
#' @section Corroboration is the trust signal:
#' Rows are collapsed to one per `(ein, name_key, city, state, zip5)` and carry
#' `n_corroborators`, the count of **distinct filers** who wrote that string for
#' that EIN. One filer's typo and a brand name fifty foundations independently
#' use are both "observed names"; only the corroborator count separates them.
#' It becomes a spec filter (§5) rather than a threshold baked into a script.
#'
#' @section The pairing link:
#' A grantmaker wrote a name *and an address together*, and that pairing is real
#' information. Each observed address carries the `name_id` it was seen with, so
#' the compiler emits roughly *k + m* rows per EIN rather than *k x m* (§8).
#' Losing the link is what turns a useful source into a row explosion.
#'
#' @section Grouping on a key, storing the raw string:
#' Deduplication needs some normalisation or trivial punctuation differences
#' become separate variants. Rows are grouped on a light key - uppercased,
#' non-alphanumerics stripped, whitespace collapsed - but the stored `name_raw`
#' is the **most frequently written raw form** within the group, so the database
#' still holds a string a filer actually typed rather than a normalised
#' reconstruction. `np_normalize()` derived columns are built from that raw
#' string later, exactly as for BMF rows.
#'
#' @param version Pinned `schedi` version, e.g. `"v2_2"`.
#' @param years Years to load. Defaults to every file present.
#' @param con A connection from [md_db()].
#' @param min_corroborators Drop groups written by fewer than this many distinct
#'   filers. `1` keeps everything; filtering belongs in the spec, so the default
#'   loads all of it.
#' @return Row counts, invisibly.
#' @export
md_ingest_schedi <- function(version = "v2_2", years = NULL, con = NULL,
                             min_corroborators = 1L) {
  dir <- md_path("sources", "schedi", version)
  files <- list.files(dir, pattern = "^SI-P02-T01-GRANTS-US-ORGS-GOVTS-[0-9]{4}[.]CSV$",
                      full.names = TRUE)
  if (!length(files)) stop("no Schedule I files in ", dir, call. = FALSE)
  if (!is.null(years)) {
    keep <- as.integer(sub(".*-([0-9]{4})[.]CSV$", "\\1", files)) %in% years
    files <- files[keep]
  }

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- paste0("schedi-", version)
  msg <- function(...) message(sprintf(...))
  msg("schedule I: %d year files", length(files))

  glob <- file.path(dir, "SI-P02-T01-GRANTS-US-ORGS-GOVTS-*.CSV")

  # Raw grant rows, restricted to what an alias needs. The recipient EIN is
  # SI_02_GRANT_US_ORG_EIN; EIN2 on the row is the *filer*.
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE VIEW si_raw AS
    SELECT
      EIN2                                        AS filer_ein,
      TAX_YEAR                                    AS tax_year,
      SI_02_GRANT_US_ORG_EIN                      AS recipient_ein_raw,
      trim(coalesce(SI_02_GRANT_US_ORG_NAME_L1,'') || ' ' ||
           coalesce(SI_02_GRANT_US_ORG_NAME_L2,''))   AS name_raw,
      trim(coalesce(SI_02_GRANT_US_ORG_ADDR_L1,'') || ' ' ||
           coalesce(SI_02_GRANT_US_ORG_ADDR_L2,''))   AS street_raw,
      SI_02_GRANT_US_ORG_ADDR_CITY                AS city_raw,
      SI_02_GRANT_US_ORG_ADDR_STATE               AS state,
      substr(regexp_replace(coalesce(SI_02_GRANT_US_ORG_ADDR_ZIP,''),'[^0-9]','','g'),1,5) AS zip5
    FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE)", glob))

  # Recipient EIN to EIN2. Anything that is not nine digits is dropped rather
  # than coerced: a mangled identifier attaches one charity's rows to another.
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE si_clean AS
    SELECT
      'EIN-' || substr(d,1,2) || '-' || substr(d,3,9) AS ein,
      filer_ein, tax_year, name_raw, street_raw, city_raw, state, zip5,
      trim(regexp_replace(regexp_replace(upper(name_raw), '[^A-Z0-9 ]', '', 'g'),
                          ' +', ' ', 'g'))                    AS name_key
    FROM (
      SELECT *, lpad(regexp_replace(coalesce(recipient_ein_raw,''),'[^0-9]','','g'), 9, '0') AS d
      FROM si_raw
      WHERE length(regexp_replace(coalesce(recipient_ein_raw,''),'[^0-9]','','g')) BETWEEN 1 AND 9
    )
    WHERE name_raw <> ''")
  n_raw <- .md_n(con, "si_clean")
  msg("  %s grant rows with a usable recipient EIN and name",
      format(n_raw, big.mark = ","))

  # A name is one row per (ein, name), not per (ein, name, place). Grouping by
  # place too inflated the table 31% with the same string repeated at each
  # address it was seen at, and every one of those rows would multiply out again
  # at compile time (section 8). The place lives on the address rows instead, which is
  # where it belongs and where the pairing link already carries it.
  #
  # n_corroborators is therefore counted over the whole name: distinct filers
  # who wrote that string for that EIN, wherever they said it was.
  # The representative spelling is the most frequent one, with ties broken
  # alphabetically. DuckDB's mode() breaks ties arbitrarily, and arbitrarily is
  # not the same as deterministically: two runs over identical input produced
  # address counts differing by one, because a tie between '' and a real street
  # flipped which side of the non-empty filter a row landed on. A build that
  # cannot reproduce its own row count cannot be cited by a spec hash (7c).
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE si_alias AS
    WITH agg AS (
      SELECT ein, name_key,
             count(*)                           AS n_obs,
             count(DISTINCT filer_ein)          AS n_corroborators,
             min(TRY_CAST(tax_year AS INTEGER)) AS first_year,
             max(TRY_CAST(tax_year AS INTEGER)) AS last_year
      FROM si_clean WHERE trim(name_key) <> ''
      GROUP BY 1,2 HAVING count(DISTINCT filer_ein) >= %d
    ), %s
    SELECT a.*, s.name_raw
    FROM agg a JOIN modal_name_raw s USING (ein, name_key)
    WHERE s.rk = 1", as.integer(min_corroborators),
    md_modal_sql("si_clean", c("ein", "name_key"), "name_raw",
                 where = "trim(name_key) <> ''")))
  n_alias <- .md_n(con, "si_alias")
  msg("  %s distinct (ein, name) aliases", format(n_alias, big.mark = ","))

  # Places for those names. City is upper-cased in the key: leaving it raw split
  # CHICAGO from Chicago and produced two rows for one address.
  place_by <- c("ein", "name_key", "city_key", "state_key", "zip5")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE si_place AS
    WITH k AS (
      SELECT *, upper(trim(coalesce(city_raw,''))) AS city_key,
                upper(trim(coalesce(state,'')))    AS state_key
      FROM si_clean WHERE trim(name_key) <> ''
    ), agg AS (
      SELECT ein, name_key, city_key, state_key, zip5, count(*) AS n_obs,
             min(tax_year)::VARCHAR AS first_vintage, max(tax_year)::VARCHAR AS last_vintage
      FROM k GROUP BY 1,2,3,4,5
    ), %s, %s
    SELECT a.ein, a.name_key, a.city_key, a.state_key, a.zip5,
           st.street_raw, ct.city_raw, a.n_obs, a.first_vintage, a.last_vintage
    FROM agg a
    JOIN modal_street_raw st USING (ein, name_key, city_key, state_key, zip5)
    JOIN modal_city_raw   ct USING (ein, name_key, city_key, state_key, zip5)
    WHERE st.rk = 1 AND ct.rk = 1",
    md_modal_sql("k", place_by, "street_raw"),
    md_modal_sql("k", place_by, "city_raw")))

  # Idempotence: a full load keyed on source_vintage (section 10), so a re-run
  # replaces rather than appends. Addresses go first because they carry the
  # name_id foreign key.
  DBI::dbExecute(con, "DELETE FROM address WHERE source = 'schedi'")
  DBI::dbExecute(con, "DELETE FROM name WHERE source = 'schedi'")

  ## ---- entities not already known --------------------------------------------
  # A recipient EIN absent from every BMF release is a filer_only entity (3a).
  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO entity (ein, layer, active, source_vintage)
    SELECT DISTINCT a.ein, 'filer_only', FALSE, '%s'
    FROM si_alias a LEFT JOIN entity e USING (ein)
    WHERE e.ein IS NULL", vintage))
  msg("  %s recipient EINs new to the database (layer = filer_only)",
      format(n_new, big.mark = ","))

  ## ---- names ------------------------------------------------------------------
  base_name <- DBI::dbGetQuery(con, "SELECT coalesce(max(name_id),0) AS m FROM name")$m
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE si_name AS
    SELECT %s + row_number() OVER () AS name_id, *
    FROM si_alias", format(base_name, scientific = FALSE)))

  DBI::dbExecute(con, sprintf("
    INSERT INTO name (name_id, ein, name_raw, variant_class, source,
                      source_vintage, n_obs, n_corroborators, first_year, last_year)
    SELECT name_id, ein, name_raw, 'observed', 'schedi', '%s',
           n_obs, n_corroborators, first_year, last_year
    FROM si_name", vintage))

  ## ---- addresses, carrying the pairing link -----------------------------------
  base_addr <- DBI::dbGetQuery(con, "SELECT coalesce(max(address_id),0) AS m FROM address")$m
  n_addr <- DBI::dbExecute(con, sprintf("
    INSERT INTO address (address_id, ein, name_id, street_raw, city_raw, state,
                         zip5, variant_class, spell_rank, source, source_vintage,
                         n_obs, first_vintage, last_vintage)
    SELECT %s + row_number() OVER (), p.ein, n.name_id, p.street_raw, p.city_raw,
           p.state_key, p.zip5, 'observed', 0, 'schedi', '%s', p.n_obs,
           p.first_vintage, p.last_vintage
    FROM si_place p JOIN si_name n USING (ein, name_key)
    WHERE coalesce(p.street_raw,'') <> '' OR coalesce(p.city_raw,'') <> ''",
    format(base_addr, scientific = FALSE), vintage))

  msg("  %s observed names, %s observed addresses",
      format(n_alias, big.mark = ","), format(n_addr, big.mark = ","))

  for (tb in list(c("name", n_alias), c("address", n_addr), c("entity", n_new))) {
    md_record_vintage(con, "schedi", version, paste0(tb[1], ":observed"),
                      as.integer(tb[2]),
                      build_note = sprintf("md_ingest_schedi(min_corroborators=%d)",
                                           as.integer(min_corroborators)))
  }

  DBI::dbExecute(con, "DROP VIEW IF EXISTS si_raw")
  invisible(stats::setNames(c(n_alias, n_addr, n_new),
                            c("names", "addresses", "new_entities")))
}
