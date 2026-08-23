#' Add historical group membership from the NCCS group metadata
#'
#' `metadata-group-number` records, per EIN, the group exemption number observed
#' across vintages as a `;;`-delimited history, plus `.last` and `.best`
#' resolutions of it.
#'
#' @section This is a small source, and saying so is part of the job:
#' Measured against the database before loading it:
#'
#' \preformatted{
#'                        meta file     BMF
#'   EINs with a GEN         33,274   647,569
#'   distinct GENs            2,958     4,917
#' }
#'
#' Of the 33,274, 27,065 agree with the BMF, 5,180 carry a GEN the BMF does not,
#' and 1,219 disagree. The net contribution is **2,913 new parent-to-member
#' pairs against 320,117 already present** - under 1%.
#'
#' It is loaded anyway because those 5,180 are not noise: an EIN whose history
#' records a group the current BMF does not is one that *left* a group, and
#' former membership is exactly what explains a lingering name similarity to a
#' national parent. That is worth having in a disambiguation database even at
#' this volume. What would not be worth having is pretending it is bigger.
#'
#' @section Conflicts resolve to the BMF, on vintage rather than preference:
#' The 1,219 disagreements are settled by taking the BMF's value, because this
#' file is a **2023-09** extract and the pinned BMF is **2026-07**. That is a
#' statement about which snapshot is more recent, not a judgement that NCCS is
#' less reliable than the IRS. If a newer group extract arrives the rule should
#' be re-examined rather than inherited.
#'
#' In practice the rule is enforced by construction: rows are only added for EINs
#' where the BMF has no GEN at all, so a conflict can never overwrite anything.
#' The count is reported so the disagreement is visible rather than absorbed.
#'
#' @section Why the other two files are not loaded:
#' `metadata-group-aff` and `metadata-group-return` are the same 835,340 EINs
#' with `group.aff.incl` and `group.return` flags, and both are **95.4% null**.
#' What they describe is *filing behaviour* - whether an organisation is included
#' in a group return - rather than structure. That is a property of a filing, not
#' a relation between two EINs, so it has no home in `ein_relation` and no
#' bearing on disambiguation. They stay registered and unloaded.
#'
#' @param con A connection from [md_db()].
#' @param path Path to `metadata-group-number.csv`.
#' @return Row counts, invisibly.
#' @export
md_ingest_group_meta <- function(con = NULL, path = NULL) {
  if (is.null(path)) {
    path <- md_path("sources", "meta_group_number", "2023-09",
                    "metadata-group-number.csv")
  }
  if (!file.exists(path)) stop("no group metadata at ", path, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- "meta_group_number-2023-09"
  msg <- function(...) message(sprintf(...))

  # The GEN arrives as a float string ("155.0") and the BMF holds it
  # zero-padded to four characters ("0155"), so both sides are normalised to the
  # BMF's form before anything is compared.
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE mg AS
    SELECT
      'EIN-' || substr(d,1,2) || '-' || substr(d,3,9) AS ein,
      lpad(regexp_replace(split_part(best, '.', 1), '[^0-9]', '', 'g'), 4, '0') AS gen
    FROM (
      SELECT lpad(regexp_replace(EIN,'[^0-9]','','g'), 9, '0') AS d,
             \"group.exempt.num.best\" AS best
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, quote='\"', escape='\"')
      WHERE nullif(\"group.exempt.num.best\",'') IS NOT NULL
    )
    WHERE length(regexp_replace(best,'[^0-9]','','g')) > 0", gsub("\\\\", "/", path)))
  n_gen <- .md_n(con, "mg")
  msg("  %s EINs carry a group exemption number", format(n_gen, big.mark = ","))

  conflict <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM mg m JOIN entity e USING (ein)
    WHERE e.group_exemption_number NOT IN ('', '0000')
      AND e.group_exemption_number IS NOT NULL
      AND e.group_exemption_number <> m.gen")$n
  msg("  %s disagree with the BMF and are left as the BMF has them (2026-07 over 2023-09)",
      format(conflict, big.mark = ","))

  DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'meta_gen'")
  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m

  # Parent-to-member, exactly as md_ingest_relations() does it, but only for EINs
  # the BMF gives no group at all. A former member and a current one are not the
  # same claim, so the relation is marked as historical in `evidence`.
  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO ein_relation (%s)
    SELECT %s + row_number() OVER (), p.ein, m.ein, NULL, 'group_member',
           'group.exempt.num.best', 'nccs_group_metadata_historical', NULL,
           NULL, NULL, NULL, 'meta_gen', '%s'
    FROM mg m
    JOIN entity e ON e.ein = m.ein
    JOIN entity p ON p.group_exemption_number = m.gen AND p.affiliation_code = '6'
    WHERE (e.group_exemption_number IS NULL OR e.group_exemption_number IN ('', '0000'))
      AND p.ein <> m.ein", .md_relation_cols(), format(base, scientific = FALSE), vintage))
  msg("  %s historical group_member pairs added", format(n_new, big.mark = ","))

  md_record_vintage(con, "meta_group_number", "2023-09",
                    "ein_relation:group_member_historical", as.integer(n_new),
                    build_note = "md_ingest_group_meta()")
  total <- .md_n(con, "ein_relation")
  msg("  ein_relation: %s rows", format(total, big.mark = ","))
  invisible(stats::setNames(c(n_gen, conflict, n_new),
                            c("with_gen", "conflicts", "added")))
}
