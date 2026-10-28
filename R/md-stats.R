#' Build the per-cell corpus statistics
#'
#' Corpus statistics depend on which rows a spec selects (`PLAN.md` section
#' 6a), so they cannot be one number per name. They can be one number per
#' *cell*, where a cell is `layer x variant_class x corroboration band`: every
#' spec without a cross-cutting filter is a union of cells, and its statistics
#' are the exact sum of its cells' (section 6c).
#'
#' Counted over `name_compact` rows, one per `(ein, name_key)`. Each such row is
#' in exactly one cell - one layer per EIN, one variant class per row - so the
#' sums are exact for EIN counts too, not just row counts.
#'
#' \describe{
#'   \item{`stat_cell`}{`layer, variant_class, band, n_rows`}
#'   \item{`stat_name_cell`}{`layer, variant_class, band, name_key, n_eins`:
#'     EINs holding the name in that cell}
#'   \item{`stat_token_cell`}{`layer, variant_class, band, token, n_rows`: name
#'     rows containing the token, by [npnormalize::np_token_idf()]'s rules - split
#'     on space, unique per name, at least two characters, no stopwords}
#' }
#'
#' @section Name rows, not frame rows:
#' npmatch's own [npnormalize::np_name_freq()] and [npnormalize::np_token_idf()] count
#' rows of the compiled frame, where a name is repeated once per paired address.
#' These cells count names, so an EIN with three addresses counts once. The
#' difference is real and [md_compile()] reports both.
#'
#' @param con A connection from [md_db()].
#' @return Row counts of the three tables, invisibly.
#' @export
md_build_stats <- function(con = NULL) {
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  if (!DBI::dbExistsTable(con, "name_compact")) {
    stop("name_compact does not exist - run md_build_compact() first", call. = FALSE)
  }
  duckdb::duckdb_register(con, "st_stop",
                          data.frame(word = toupper(npnormalize::np_stopwords())))
  on.exit(duckdb::duckdb_unregister(con, "st_stop"), add = TRUE)

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE st_rows AS
    SELECT c.ein, upper(c.name_key) AS name_key, e.layer, c.variant_class,
           %s AS band
    FROM name_compact c JOIN entity e USING (ein)
    WHERE %s", .md_band_sql("c.variant_class",
                                                               "c.n_corroborators"),
    if ("guard_any" %in% DBI::dbListFields(con, "name_compact"))
      "NOT coalesce(c.guard_any, FALSE)" else "TRUE"))
  DBI::dbExecute(con, "DROP TABLE IF EXISTS stat_cell")
  DBI::dbExecute(con, "CREATE TABLE stat_cell AS
    SELECT layer, variant_class, band, count(*) AS n_rows
    FROM st_rows GROUP BY 1, 2, 3 ORDER BY 1, 2, 3")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS stat_name_cell")
  DBI::dbExecute(con, "CREATE TABLE stat_name_cell AS
    SELECT layer, variant_class, band, name_key, count(*) AS n_eins
    FROM st_rows GROUP BY 1, 2, 3, 4")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS stat_token_cell")
  DBI::dbExecute(con, "CREATE TABLE stat_token_cell AS
    SELECT layer, variant_class, band, token, count(*) AS n_rows
    FROM (SELECT DISTINCT ein, name_key, layer, variant_class, band, token
          FROM (SELECT *, unnest(string_split(name_key, ' ')) AS token FROM st_rows))
    WHERE length(token) >= 2 AND token NOT IN (SELECT word FROM st_stop)
    GROUP BY 1, 2, 3, 4")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS st_rows")

  out <- vapply(c("stat_cell", "stat_name_cell", "stat_token_cell"),
                function(t) .md_n(con, t), numeric(1))
  msg("  stat_cell %s cells; stat_name_cell %s rows; stat_token_cell %s rows",
      format(out[1], big.mark = ","), format(out[2], big.mark = ","),
      format(out[3], big.mark = ","))
  invisible(out)
}
