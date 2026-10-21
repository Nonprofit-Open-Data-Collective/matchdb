#' Fill the resolved NTEE triple on entity
#'
#' Populates `ntee_code`, `ntee_rule`, `ntee_agreement`, `ntee_n_distinct`,
#' `ntee_source` and `nteev2` (§4) by combining the BMF snapshot with the
#' canonical NTEE crosswalk.
#'
#' @section The resolution rule:
#' \enumerate{
#'   \item **`bmf_current`** - the organisation is in the current active BMF
#'     release and the BMF carries an NTEE code. What the IRS says now wins for
#'     an organisation that currently exists.
#'   \item **`modal`** - otherwise, the code observed in the most vintages.
#'     Robust to a single mis-keyed year, which a most-recent rule is not.
#'   \item **`most_recent`** - if there is no modal value.
#'   \item **`bmf_only`** - for EINs absent from the crosswalk entirely, the BMF
#'     code, whatever its vintage.
#'   \item `NULL` with `ntee_rule = 'none'` when no source has a code.
#' }
#'
#' @section What the measurements say about this rule:
#' Three findings shaped it, all against the pinned BMF and crosswalk.
#'
#' **The BMF and the crosswalk's `ntee_current` are the same value, not two
#' opinions.** Among active EINs where the crosswalk has a `current` code, it
#' agrees with the BMF on 1,382,208 and differs on 608 - 99.96%. So there is no
#' choice to make between "the BMF version" and "the crosswalked current
#' version"; the real choice is between *now* and *history*.
#'
#' **The BMF's NTEE is missing far more often for active organisations than
#' inactive ones** - 29.4% against 3.6%. The fallback is therefore not an edge
#' case: rule 1 leaves 581,028 active organisations to be resolved by rule 2.
#' The inversion is not a defect; legacy rows inherit NTEE from NCCS series that
#' assigned it, while the current IRS extract often does not.
#'
#' **For active organisations the BMF code and the modal code disagree 38.8% of
#' the time** (741,207 of 1,911,130), so rule 1 versus rule 2 is a consequential
#' choice rather than a formality. For inactive organisations modal and
#' most-recent differ only 4.1%, so rule 3 is nearly free.
#'
#' @section nteev2 is recomputed, and how well depends on the rule:
#' `fiscal::get_nteev2()` is applied to the chosen code rather than any stored
#' rendering, because both the BMF and the crosswalk ship the specialty
#' double-encoding defect (`?md_ntee_canonical`).
#'
#' One honest limitation. Rule 1 recomputes from `ntee_code_raw`, which
#' preserves the legacy five-character form and so gets the `B8443 -> B43` rule
#' right. Rules 2 and 3 only have the crosswalk's three-character code, where
#' that information is already gone. `ntee_source` records which, so rows whose
#' NTEEv2 rests on a truncated input are identifiable rather than merely
#' suspected.
#'
#' @param version The pinned `bmf_unified` version (for the active-vintage test).
#' @param crosswalk Path to `ntee_resolved_crosswalk.csv`.
#' @param crosswalk_version Pinned `ntee_crosswalk` version, used when `crosswalk` is `NULL`.
#' @param con A connection from [md_db()].
#' @return A table of rule counts, invisibly.
#' @export
md_ingest_ntee <- function(version, crosswalk = NULL, con = NULL,
                           crosswalk_version = "2026-08") {
  if (is.null(crosswalk)) {
    crosswalk <- md_path("sources", "ntee_crosswalk", crosswalk_version,
                         "ntee_resolved_crosswalk.csv")
  }
  if (!file.exists(crosswalk)) stop("no NTEE crosswalk at ", crosswalk, call. = FALSE)
  if (!requireNamespace("fiscal", quietly = TRUE)) {
    stop("the 'fiscal' package supplies get_nteev2(); matchdb does not ",
         "reimplement it, because two copies of a classification rule is ",
         "exactly the drift hazard this database exists to prevent.", call. = FALSE)
  }

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }

  DBI::dbExecute(con, sprintf(
    "CREATE OR REPLACE VIEW ntee_xw AS
     SELECT EIN2 AS ein, nullif(ntee_current,'') AS xw_current,
            nullif(ntee_most_recent,'') AS xw_most_recent,
            nullif(ntee_modal,'') AS xw_modal,
            nullif(ntee_agreement,'') AS agreement,
            TRY_CAST(n_distinct_codes AS INTEGER) AS n_distinct,
            nullif(ntee_most_recent_source,'') AS xw_source
     FROM read_csv_auto('%s', ALL_VARCHAR=TRUE)", crosswalk))

  # Resolve. Kept as one CASE ladder so the rule is legible in one place and
  # the recorded ntee_rule cannot drift from the branch that produced it.
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE ntee_resolved AS
    SELECT
      e.ein,
      CASE
        WHEN e.active AND nullif(e.ntee_code_raw,'') IS NOT NULL THEN e.ntee_code_raw
        WHEN x.xw_modal       IS NOT NULL THEN x.xw_modal
        WHEN x.xw_most_recent IS NOT NULL THEN x.xw_most_recent
        WHEN nullif(e.ntee_code_raw,'') IS NOT NULL THEN e.ntee_code_raw
      END AS ntee_code,
      CASE
        WHEN e.active AND nullif(e.ntee_code_raw,'') IS NOT NULL THEN 'bmf_current'
        WHEN x.xw_modal       IS NOT NULL THEN 'modal'
        WHEN x.xw_most_recent IS NOT NULL THEN 'most_recent'
        WHEN nullif(e.ntee_code_raw,'') IS NOT NULL THEN 'bmf_only'
        ELSE 'none'
      END AS ntee_rule,
      x.agreement  AS ntee_agreement,
      x.n_distinct AS ntee_n_distinct,
      CASE
        WHEN e.active AND nullif(e.ntee_code_raw,'') IS NOT NULL THEN 'bmf:ntee_code_raw'
        WHEN x.xw_modal IS NOT NULL OR x.xw_most_recent IS NOT NULL
          THEN 'crosswalk:' || coalesce(x.xw_source,'unknown') || ' (3-char)'
        WHEN nullif(e.ntee_code_raw,'') IS NOT NULL THEN 'bmf:ntee_code_raw'
      END AS ntee_source
    FROM entity e LEFT JOIN ntee_xw x USING (ein)")

  codes <- DBI::dbGetQuery(con, "SELECT ein, ntee_code FROM ntee_resolved")
  codes$nteev2 <- NA_character_
  has <- !is.na(codes$ntee_code) & nzchar(codes$ntee_code)
  codes$nteev2[has] <- fiscal::get_nteev2(codes$ntee_code[has])
  DBI::dbWriteTable(con, "ntee_v2", codes[, c("ein", "nteev2")], overwrite = TRUE)

  DBI::dbExecute(con, "
    CREATE OR REPLACE TABLE entity AS
    SELECT e.* REPLACE (
             r.ntee_code       AS ntee_code,
             r.ntee_rule       AS ntee_rule,
             r.ntee_agreement  AS ntee_agreement,
             r.ntee_n_distinct AS ntee_n_distinct,
             r.ntee_source     AS ntee_source,
             v.nteev2          AS nteev2)
    FROM entity e
    LEFT JOIN ntee_resolved r USING (ein)
    LEFT JOIN ntee_v2 v USING (ein)")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS ntee_v2")
  DBI::dbExecute(con, "DROP VIEW IF EXISTS ntee_xw")

  out <- DBI::dbGetQuery(con, "
    SELECT ntee_rule, active, count(*) AS n
    FROM entity GROUP BY 1,2 ORDER BY n DESC")
  print(out)
  invisible(out)
}
