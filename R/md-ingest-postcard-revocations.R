#' Ingest the Form 990-N e-Postcard
#'
#' The e-Postcard is the only filing the smallest organisations make: gross
#' receipts normally under $50,000, no full 990, so no e-file table ever sees
#' them. For 834,305 of its EINs the BMF was the only source of a name before
#' this ingest.
#'
#' The NCCS file holds **one row per EIN, its latest postcard** (tax years
#' 2007-2025 in the 2026-07 file), so it gives a current address, not an address
#' history. It writes:
#'
#' \describe{
#'   \item{`entity`}{EINs in no other source, as `layer = 'postcard_only'`
#'     (73,503 in the 2026-07 file).}
#'   \item{`name`}{the legal name and up to three DBAs, `source = 'e_postcard'`,
#'     with the postcard's tax year as `first_year` and `last_year`.}
#'   \item{`address`}{the organisation's address as `mailing`, as of that year.}
#'   \item{`entity_event`}{`terminated_990n` where the postcard says the
#'     organisation has terminated, dated by the end of its tax period.}
#' }
#'
#' The officer name and address are not read: they describe a person. The
#' website field is read by [md_ingest_websites()].
#'
#' @param version Pinned `e_postcard` version, e.g. `"v2026-07"`.
#' @param con A connection from [md_db()].
#' @return Row counts, invisibly.
#' @export
md_ingest_e_postcard <- function(version, con = NULL) {
  f <- Sys.glob(md_path("sources", "e_postcard", version, "*-E-POSTCARD.csv"))
  if (length(f) != 1L) stop("expected one *-E-POSTCARD.csv for e_postcard/", version,
                            call. = FALSE)
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  vintage <- paste0("e_postcard-", version)

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE pc AS
    SELECT 'EIN-' || substr(d, 1, 2) || '-' || substr(d, 3, 9) AS ein,
           try_cast(tax_year AS INT) AS yr,
           upper(coalesce(terminated, '')) IN ('T', 'TRUE', 'Y', '1') AS terminated,
           try_strptime(tax_period_end_date, '%%m-%%d-%%Y')::DATE AS period_end,
           trim(coalesce(legal_name, '')) AS legal,
           trim(coalesce(dba_name_1, '')) AS dba1, trim(coalesce(dba_name_2, '')) AS dba2,
           trim(coalesce(dba_name_3, '')) AS dba3,
           trim(coalesce(organization_address_line_1, '')) AS street_raw,
           trim(coalesce(organization_city, '')) AS city_raw,
           upper(trim(coalesce(organization_state, ''))) AS state,
           substr(regexp_replace(coalesce(organization_zip, ''), '[^0-9]', '', 'g'), 1, 5) AS zip5,
           CASE WHEN length(regexp_replace(coalesce(organization_zip, ''), '[^0-9]', '', 'g')) = 9
                THEN substr(regexp_replace(organization_zip, '[^0-9]', '', 'g'), 6, 4) END AS zip_plus4
    FROM (SELECT *, lpad(regexp_replace(coalesce(ein, ''), '[^0-9]', '', 'g'), 9, '0') AS d
          FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, quote='\"', escape='\"'))
    WHERE length(regexp_replace(coalesce(ein, ''), '[^0-9]', '', 'g')) BETWEEN 1 AND 9",
    gsub("\\\\", "/", f)))
  msg("e-postcard: %s postcards", format(.md_n(con, "pc"), big.mark = ","))

  DBI::dbExecute(con, "DELETE FROM name WHERE source = 'e_postcard'")
  DBI::dbExecute(con, "DELETE FROM address WHERE source = 'e_postcard'")
  .md_ensure_entity_event(con)
  DBI::dbExecute(con, "DELETE FROM entity_event WHERE source = 'e_postcard'")

  n_ent <- DBI::dbExecute(con, sprintf("
    INSERT INTO entity (ein, layer, active, source_vintage)
    SELECT DISTINCT p.ein, 'postcard_only', FALSE, '%s'
    FROM pc p LEFT JOIN entity e USING (ein) WHERE e.ein IS NULL", vintage))
  msg("  %s EINs new to the database (layer = postcard_only)", format(n_ent, big.mark = ","))

  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE pc_names AS
    SELECT ein, yr, 'legal' AS variant_class, legal AS name_raw FROM pc WHERE legal <> ''
    UNION ALL SELECT ein, yr, 'dba', dba1 FROM pc WHERE dba1 <> ''
    UNION ALL SELECT ein, yr, 'dba', dba2 FROM pc WHERE dba2 <> ''
    UNION ALL SELECT ein, yr, 'dba', dba3 FROM pc WHERE dba3 <> ''")
  n_name <- .md_insert_named_rows(con, "pc_names", "e_postcard", vintage)
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE pc_addr AS
    SELECT ein, yr, 'mailing' AS variant_class, street_raw, city_raw, state, zip5, zip_plus4
    FROM pc WHERE street_raw <> ''")
  n_addr <- .md_insert_address_rows(con, "pc_addr", "e_postcard", vintage)
  n_ev <- DBI::dbExecute(con, sprintf("
    INSERT INTO entity_event (ein, event, event_date, event_year, source, source_vintage)
    SELECT ein, 'terminated_990n', period_end, yr, 'e_postcard', '%s'
    FROM pc WHERE terminated", vintage))
  msg("  %s names, %s addresses, %s terminations", format(n_name, big.mark = ","),
      format(n_addr, big.mark = ","), format(n_ev, big.mark = ","))

  for (tb in list(c("entity:postcard_only", n_ent), c("name:e_postcard", n_name),
                  c("address:e_postcard", n_addr), c("entity_event:e_postcard", n_ev))) {
    md_record_vintage(con, "e_postcard", version, tb[1], as.integer(tb[2]),
                      build_note = "md_ingest_e_postcard()",
                      content_vintage = as.character(DBI::dbGetQuery(con,
                        "SELECT max(yr) AS y FROM pc")$y),
                      content_vintage_rule = "measured")
  }
  DBI::dbExecute(con, "DROP TABLE IF EXISTS pc")
  invisible(c(entities = n_ent, names = n_name, addresses = n_addr, events = n_ev))
}

#' Ingest the IRS automatic revocation list
#'
#' An organisation that files nothing for three consecutive years loses its
#' exemption automatically. The list is the record of that: for each EIN, when
#' it was revoked, when the revocation was posted and, if it happened, when the
#' exemption was reinstated - dates the BMF does not carry. An EIN may appear
#' more than once (18,909 twice, 176 three times in the 2026-07 file).
#'
#' It writes:
#' \describe{
#'   \item{`entity`}{EINs in no other source, as `layer = 'revoked_only'`
#'     (154,775 in the 2026-07 file; mostly 501(c)(4)s revoked in 2010 and
#'     2016-2018).}
#'   \item{`entity_event`}{`revoked`, `revocation_posted` and `reinstated`,
#'     each with its date. This is what a temporal veto reads: a grant to an
#'     organisation revoked years before the grant year is suspect
#'     (`REDUCTION.md` section 6c).}
#'   \item{`name`}{the legal name and DBA as of revocation,
#'     `source = 'revocations'`.}
#'   \item{`address`}{the address as of revocation, as `historical`: it was
#'     true then and may not be now.}
#' }
#'
#' @param version Pinned `revocations` version, e.g. `"v2026-07"`.
#' @param con A connection from [md_db()].
#' @return Row counts, invisibly.
#' @export
md_ingest_revocations <- function(version, con = NULL) {
  f <- Sys.glob(md_path("sources", "revocations", version, "*-REVOCATIONS-ORGS.csv"))
  if (length(f) != 1L) stop("expected one *-REVOCATIONS-ORGS.csv for revocations/", version,
                            call. = FALSE)
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  vintage <- paste0("revocations-", version)
  dmy <- function(col) sprintf("try_strptime(nullif(trim(%s), ''), '%%d-%%b-%%Y')::DATE", col)

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE rv AS
    SELECT 'EIN-' || substr(d, 1, 2) || '-' || substr(d, 3, 9) AS ein,
           %s AS revoked, %s AS posted, %s AS reinstated,
           trim(coalesce(legal_name, '')) AS legal,
           trim(coalesce(doing_business_as_name, '')) AS dba,
           trim(coalesce(organization_address, '')) AS street_raw,
           trim(coalesce(city, '')) AS city_raw, upper(trim(coalesce(state, ''))) AS state,
           substr(regexp_replace(coalesce(zip_code, ''), '[^0-9]', '', 'g'), 1, 5) AS zip5,
           CASE WHEN length(regexp_replace(coalesce(zip_code, ''), '[^0-9]', '', 'g')) = 9
                THEN substr(regexp_replace(zip_code, '[^0-9]', '', 'g'), 6, 4) END AS zip_plus4,
           nullif(trim(exemption_type), '') AS exemption_type
    FROM (SELECT *, lpad(regexp_replace(coalesce(ein, ''), '[^0-9]', '', 'g'), 9, '0') AS d
          FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, quote='\"', escape='\"'))
    WHERE length(regexp_replace(coalesce(ein, ''), '[^0-9]', '', 'g')) BETWEEN 1 AND 9",
    dmy("revocation_date"), dmy("revocation_posting_date"),
    dmy("exemption_reinstatement_date"), gsub("\\\\", "/", f)))
  bad_dates <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM rv WHERE revoked IS NULL")$n
  msg("revocations: %s rows; %s without a parseable revocation date",
      format(.md_n(con, "rv"), big.mark = ","), format(bad_dates, big.mark = ","))

  DBI::dbExecute(con, "DELETE FROM name WHERE source = 'revocations'")
  DBI::dbExecute(con, "DELETE FROM address WHERE source = 'revocations'")
  .md_ensure_entity_event(con)
  DBI::dbExecute(con, "DELETE FROM entity_event WHERE source = 'revocations'")

  n_ent <- DBI::dbExecute(con, sprintf("
    INSERT INTO entity (ein, layer, active, source_vintage)
    SELECT DISTINCT r.ein, 'revoked_only', FALSE, '%s'
    FROM rv r LEFT JOIN entity e USING (ein) WHERE e.ein IS NULL", vintage))
  msg("  %s EINs new to the database (layer = revoked_only)", format(n_ent, big.mark = ","))

  n_ev <- DBI::dbExecute(con, sprintf("
    INSERT INTO entity_event (ein, event, event_date, event_year, detail, source, source_vintage)
    SELECT DISTINCT ein, event, d, year(d), exemption_type, 'revocations', '%s' FROM (
      SELECT ein, 'revoked' AS event, revoked AS d, exemption_type FROM rv
      UNION ALL SELECT ein, 'revocation_posted', posted, exemption_type FROM rv
      UNION ALL SELECT ein, 'reinstated', reinstated, exemption_type FROM rv)
    WHERE d IS NOT NULL", vintage))

  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE rv_names AS
    SELECT ein, year(revoked) AS yr, 'legal' AS variant_class, legal AS name_raw FROM rv WHERE legal <> ''
    UNION ALL SELECT ein, year(revoked), 'dba', dba FROM rv WHERE dba <> ''")
  n_name <- .md_insert_named_rows(con, "rv_names", "revocations", vintage)
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE rv_addr AS
    SELECT ein, year(revoked) AS yr, 'historical' AS variant_class,
           street_raw, city_raw, state, zip5, zip_plus4
    FROM rv WHERE street_raw <> ''")
  n_addr <- .md_insert_address_rows(con, "rv_addr", "revocations", vintage)
  msg("  %s events, %s names, %s addresses", format(n_ev, big.mark = ","),
      format(n_name, big.mark = ","), format(n_addr, big.mark = ","))

  newest <- as.character(DBI::dbGetQuery(con, "SELECT max(revoked) AS d FROM rv")$d)
  for (tb in list(c("entity:revoked_only", n_ent), c("entity_event:revocations", n_ev),
                  c("name:revocations", n_name), c("address:revocations", n_addr))) {
    md_record_vintage(con, "revocations", version, tb[1], as.integer(tb[2]),
                      build_note = "md_ingest_revocations()",
                      content_vintage = substr(newest, 1, 7), content_vintage_rule = "measured")
  }
  DBI::dbExecute(con, "DROP TABLE IF EXISTS rv")
  invisible(c(entities = n_ent, events = n_ev, names = n_name, addresses = n_addr))
}

# entity_event: dated status facts per EIN, one row per (ein, event, date,
# source). Status flips (PLAN.md section 7d), so it is a log, not a column.
.md_ensure_entity_event <- function(con) {
  if (!DBI::dbExistsTable(con, "entity_event")) {
    DBI::dbExecute(con, "CREATE TABLE entity_event (
      ein VARCHAR, event VARCHAR, event_date DATE, event_year INTEGER,
      detail VARCHAR, source VARCHAR, source_vintage VARCHAR)")
  }
}

# Write name rows from a table of (ein, yr, variant_class, name_raw): one row per
# (ein, class, spelling key), the most common spelling, the years it spans - the
# shape every first-party source writes.
.md_insert_named_rows <- function(con, tbl, source, vintage) {
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE ins_k AS
    SELECT *, trim(regexp_replace(regexp_replace(upper(name_raw), '[^A-Z0-9 ]', '', 'g'),
                                  ' +', ' ', 'g')) AS k FROM %s", tbl))
  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(name_id), 0) AS m FROM name")$m
  n <- DBI::dbExecute(con, sprintf("
    INSERT INTO name (name_id, ein, name_raw, variant_class, source, source_vintage,
                      n_obs, n_corroborators, first_year, last_year)
    WITH agg AS (
      SELECT ein, variant_class, k, count(*) AS n_obs, min(yr) AS fy, max(yr) AS ly
      FROM ins_k WHERE k <> '' GROUP BY 1, 2, 3
    ), %s
    SELECT %s + row_number() OVER (ORDER BY a.ein, a.variant_class, a.k), a.ein,
           m.name_raw, a.variant_class, '%s', '%s', a.n_obs, NULL, a.fy, a.ly
    FROM agg a JOIN modal_name_raw m USING (ein, variant_class, k) WHERE m.rk = 1",
    md_modal_sql("ins_k", c("ein", "variant_class", "k"), "name_raw", where = "k <> ''"),
    format(base, scientific = FALSE), source, vintage))
  DBI::dbExecute(con, "DROP TABLE ins_k")
  n
}

# Write address rows from (ein, yr, variant_class, street_raw, city_raw, state,
# zip5, zip_plus4): one row per place and class, the most common spelling.
.md_insert_address_rows <- function(con, tbl, source, vintage) {
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE ins_a AS
    SELECT *, upper(street_raw) AS sk, upper(city_raw) AS ck FROM %s", tbl))
  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(address_id), 0) AS m FROM address")$m
  n <- DBI::dbExecute(con, sprintf("
    INSERT INTO address (address_id, ein, name_id, street_raw, city_raw, state, zip5,
                         zip_plus4, variant_class, spell_rank, source, source_vintage,
                         n_obs, first_vintage, last_vintage)
    WITH agg AS (
      SELECT ein, variant_class, sk, ck, state, zip5, count(*) AS n_obs,
             min(yr) AS fy, max(yr) AS ly, max(zip_plus4) AS zip_plus4
      FROM ins_a GROUP BY 1, 2, 3, 4, 5, 6
    ), %s, %s
    SELECT %s + row_number() OVER (ORDER BY a.ein, a.variant_class, a.sk, a.zip5), a.ein,
           NULL, s.street_raw, c.city_raw, a.state, a.zip5, a.zip_plus4, a.variant_class,
           row_number() OVER (PARTITION BY a.ein ORDER BY a.ly DESC NULLS LAST, a.n_obs DESC,
                                                   a.sk) - 1,
           '%s', '%s', a.n_obs, a.fy::VARCHAR, a.ly::VARCHAR
    FROM agg a
    JOIN modal_street_raw s USING (ein, variant_class, sk, ck, state, zip5)
    JOIN modal_city_raw c USING (ein, variant_class, sk, ck, state, zip5)
    WHERE s.rk = 1 AND c.rk = 1",
    md_modal_sql("ins_a", c("ein", "variant_class", "sk", "ck", "state", "zip5"), "street_raw"),
    md_modal_sql("ins_a", c("ein", "variant_class", "sk", "ck", "state", "zip5"), "city_raw"),
    format(base, scientific = FALSE), source, vintage))
  DBI::dbExecute(con, "DROP TABLE ins_a")
  n
}
