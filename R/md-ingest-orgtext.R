#' Ingest mission and program text
#'
#' Fills `orgtext`, the last empty core table: one row per
#' `(ein, tax_year, text_kind)` carrying what an organisation wrote about what it
#' does.
#'
#' @section It is adjudication input, not candidate generation:
#' Section 10 is explicit that this stays outside the name and address selection
#' machinery. `pf_purpose_tiebreak()` consumes mission text *after* a candidate
#' list exists, to choose between candidates that already look plausible. It is
#' not a blocking key and must not become one - at four million EINs and
#' paragraph-length strings, blocking on it would be a disaster.
#'
#' So `orgtext` is deliberately EIN-keyed and joined on demand. It carries no
#' `variant_class`, appears in no spec axis, and nothing in `md_compile()` will
#' ever select on it.
#'
#' @section Why it is a panel and the other tables are not:
#' `name` and `address` collapse repeated observations into one row per distinct
#' value, because a spelling written twice is not two spellings. Text is
#' different: an organisation rewrites its mission, and the rewrite is a fact
#' about that year rather than a duplicate to be merged. Rows are therefore kept
#' per `(ein, tax_year, text_kind)`, and identical text repeated across years is
#' preserved rather than deduplicated.
#'
#' @section Text is stored as filed:
#' No case folding, no punctuation stripping, no truncation. The normalised forms
#' that `name` carries exist because names are *matched on*; mission text is
#' read, quoted and shown to an adjudicator, so mangling it would destroy the
#' thing that makes it useful. Any normalisation a consumer wants is a consumer's
#' decision.
#'
#' @param version Pinned `efile_orgtext` version.
#' @param con A connection from [md_db()].
#' @param kinds Which text kinds to load. Defaults to all present.
#' @return Row counts by kind, invisibly.
#' @export
md_ingest_orgtext <- function(version = "v2_2", con = NULL, kinds = NULL) {
  dir <- md_path("sources", "efile_orgtext", version)
  if (!dir.exists(dir)) stop("no orgtext sources at ", dir, call. = FALSE)

  # table prefix -> (text_kind, text column). PROGRAM-ONE/TWO/THREE are the
  # three program slots Form 990 Part III provides; the EZ table is the same
  # question asked of 990-EZ filers, who are a different and generally smaller
  # population worth keeping distinguishable.
  spec <- list(
    list(prefix = "F9-P03-T00-MISSION",        kind = "mission",    col = "F9_03_ORG_MISSION_PURPOSE"),
    list(prefix = "F9-P03-T00-PROGRAM-ONE",    kind = "program_1",  col = "F9_03_PROG_DESC"),
    list(prefix = "F9-P03-T00-PROGRAM-TWO",    kind = "program_2",  col = "F9_03_PROG_DESC"),
    list(prefix = "F9-P03-T00-PROGRAM-THREE",  kind = "program_3",  col = "F9_03_PROG_DESC"),
    list(prefix = "F9-P03-T02-PROGRAMS-EZ",    kind = "program_ez", col = "F9_03_PROG_DESC")
  )
  if (!is.null(kinds)) spec <- Filter(function(s) s$kind %in% kinds, spec)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- paste0("efile_orgtext-", version)
  msg <- function(...) message(sprintf(...))

  if (!DBI::dbExistsTable(con, "orgtext")) {
    DBI::dbExecute(con, "
      CREATE TABLE orgtext (
        ein            VARCHAR,
        tax_year       INTEGER,
        text_kind      VARCHAR,
        text           VARCHAR,
        source         VARCHAR,
        source_vintage VARCHAR)")
  }
  DBI::dbExecute(con, "DELETE FROM orgtext WHERE source = 'efile990'")

  out <- integer(0)
  for (s in spec) {
    files <- list.files(dir, pattern = paste0("^", s$prefix, "-[0-9]{4}[.]CSV$"),
                        full.names = TRUE)
    if (!length(files)) { msg("  %-11s no files, skipped", s$kind); next }

    n <- DBI::dbExecute(con, sprintf("
      INSERT INTO orgtext
      SELECT EIN2, TRY_CAST(TAX_YEAR AS INTEGER), '%s', txt, 'efile990', '%s'
      FROM (
        SELECT EIN2, TAX_YEAR, trim(coalesce(%s, '')) AS txt
        FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE,
                           quote='\"', escape='\"')
        WHERE EIN2 IS NOT NULL AND regexp_matches(EIN2,'^EIN-[0-9]{2}-[0-9]{7}$')
      )
      WHERE txt <> ''",
      s$kind, vintage, s$col, file.path(dir, paste0(s$prefix, "-*.CSV"))))
    msg("  %-11s %s rows from %d files", s$kind, format(n, big.mark = ","), length(files))
    out[s$kind] <- n
    md_record_vintage(con, "efile_orgtext", version, paste0("orgtext:", s$kind),
                      as.integer(n), build_note = "md_ingest_orgtext()")
  }

  shape <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n_rows, count(DISTINCT ein) AS eins,
           round(avg(length(text))) AS mean_chars,
           max(length(text)) AS max_chars
    FROM orgtext")
  msg("  orgtext: %s rows over %s EINs; mean %s chars, longest %s",
      format(shape$n_rows, big.mark = ","), format(shape$eins, big.mark = ","),
      shape$mean_chars, format(shape$max_chars, big.mark = ","))

  # Coverage against the entity table is the number that decides whether mission
  # text is usable as a tiebreak at all: a signal present for a tenth of the
  # universe breaks ties for a tenth of the queue.
  cov <- DBI::dbGetQuery(con, "
    SELECT round(100.0 * count(DISTINCT o.ein) / (SELECT count(*) FROM entity), 1) AS pct
    FROM orgtext o")$pct
  msg("  covers %s%% of entities", cov)

  invisible(out)
}
