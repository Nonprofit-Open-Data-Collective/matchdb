#' Ingest officer, director and key-employee name keys from Form 990 Part VII
#'
#' Writes `person_key`: one row per `(ein, person_key)` with the years the
#' person is listed. [md_build_ein_key()] turns it into the `person` kind of
#' `ein_key`, so a hard case can find candidates through a shared board member.
#'
#' @section A key, not a directory:
#' Part VII lists people by name, with title, hours and compensation. Only the
#' name is read, and only as a matching key: uppercased, punctuation and
#' single letters removed, titles and suffixes dropped (`DR`, `REV`, `JR`, `MD`,
#' `CPA`, ...), the remaining words sorted - so `SMITH, JOHN A` and
#' `JOHN SMITH` are one key. Titles, hours and compensation are not stored, and
#' rows naming an organisation as trustee (a bank, a law firm) are skipped:
#' those are agents, not people.
#'
#' @section Most keys are weak, and n_eins_sharing says which:
#' A common name on hundreds of boards confirms nothing; an uncommon one shared
#' by two EINs is a strong link. The key is useful only with its sharing count,
#' which `ein_key` carries.
#'
#' @param version Pinned `efile_officers` version, e.g. `"v3_1"`.
#' @param con A connection from [md_db()].
#' @return Rows written, invisibly.
#' @export
md_ingest_officers <- function(version, con = NULL) {
  dir <- md_path("sources", "efile_officers", version)
  main <- file.path(dir, "F9-P07-T01-COMPENSATION-[0-9][0-9][0-9][0-9].CSV")
  ez <- file.path(dir, "F9-P07-T01-COMPENSATION-HCE-EZ-*.CSV")
  if (!length(Sys.glob(main))) stop("no Part VII compensation files in ", dir, call. = FALSE)
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  vintage <- paste0("efile_officers-", version)
  rd <- function(glob, cols) sprintf(
    "SELECT %s FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE,
                                  quote='\"', escape='\"')", cols, gsub("\\\\", "/", glob))
  parts <- rd(main, "EIN2 AS ein, try_cast(TAX_YEAR AS INT) AS yr,
                     F9_07_COMP_DTK_NAME_PERS AS nm")
  if (length(Sys.glob(ez))) {
    parts <- paste(parts, "UNION ALL", rd(ez, "EIN2 AS ein, try_cast(TAX_YEAR AS INT) AS yr,
                                               F9_07_COMP_DTK_NAME_PERS_HCE AS nm"))
  }
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE off_raw AS
    SELECT ein, yr, nm FROM (%s)
    WHERE ein IS NOT NULL AND regexp_matches(ein, '^EIN-[0-9]{2}-[0-9]{7}$')
      AND nullif(trim(nm), '') IS NOT NULL", parts))
  n_raw <- .md_n(con, "off_raw")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS person_key")
  DBI::dbExecute(con, sprintf("CREATE TABLE person_key AS
    SELECT ein, person_key, count(*) AS n_obs, min(yr) AS first_year, max(yr) AS last_year,
           'efile990' AS source, '%s' AS source_vintage
    FROM (SELECT ein, yr, %s AS person_key FROM off_raw)
    WHERE person_key IS NOT NULL
    GROUP BY ein, person_key ORDER BY ein, person_key", vintage, .md_person_key_sql("nm")))
  DBI::dbExecute(con, "DROP TABLE off_raw")
  n <- .md_n(con, "person_key")
  msg("officers: %s Part VII rows -> %s (ein, person) keys over %s EINs",
      format(n_raw, big.mark = ","), format(n, big.mark = ","),
      format(DBI::dbGetQuery(con, "SELECT count(DISTINCT ein) AS n FROM person_key")$n,
             big.mark = ","))
  md_record_vintage(con, "efile_officers", version, "person_key", as.integer(n),
                    build_note = "md_ingest_officers(); keys only, no titles or compensation")
  invisible(n)
}

# Words that are titles, honorifics or suffixes, not part of who a person is.
.md_person_drop <- c("MR", "MRS", "MS", "MISS", "DR", "REV", "REVEREND", "FR", "FATHER",
  "SR", "JR", "II", "III", "IV", "MD", "DO", "DDS", "DMD", "PHD", "EDD", "JD", "ESQ",
  "CPA", "RN", "LCSW", "MBA", "MSW", "DVM", "PE", "HON", "SISTER", "BROTHER", "PASTOR",
  "RABBI", "BISHOP", "DECEASED", "FORMER", "ETAL", "TRUSTEE", "TTEE")

# The person key as SQL over one name column: NULL when fewer than two words
# survive, since one word does not identify a person.
.md_person_key_sql <- function(col) {
  drop <- paste0("'", .md_person_drop, "'", collapse = ", ")
  sprintf("CASE WHEN len(list_filter(string_split(trim(regexp_replace(regexp_replace(
                  upper(%s), '[^A-Z ]', ' ', 'g'), ' +', ' ', 'g')), ' '),
                  w -> length(w) >= 2 AND w NOT IN (%s))) >= 2
           THEN array_to_string(list_sort(list_distinct(list_filter(
                  string_split(trim(regexp_replace(regexp_replace(upper(%s), '[^A-Z ]', ' ', 'g'),
                  ' +', ' ', 'g')), ' '), w -> length(w) >= 2 AND w NOT IN (%s)))), ' ')
           END", col, drop, col, drop)
}
