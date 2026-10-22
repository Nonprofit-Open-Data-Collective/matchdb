#' Add group membership from what filers report on Form 990 line H
#'
#' The 990 header carries three group fields that `md_ingest_efile_header()`
#' reads past: H(a) `RETURN_GROUP_X` (is this a group return), H(b)
#' `ALL_AFFIL_INCL_X` (are all subordinates included) and H(c)
#' `GROUP_EXEMPT_NUM`. H(c) is the organisation's **own** statement of the group
#' it belongs to, filed annually, and it is a different witness from the BMF.
#'
#' @section What it adds that the BMF cannot:
#' Measured over 2009-2024, 259,368 filings carry a usable GEN across 42,997
#' EINs and 3,497 groups. Against the pinned BMF:
#'
#' \preformatted{
#'   (EIN, GEN) pairs in the e-file        43,603
#'     BMF records no GEN for that EIN      7,015
#'     BMF agrees                          34,806
#'     BMF disagrees                        1,782
#' }
#'
#' The 7,015 are the point. They are organisations that told the IRS on their own
#' return which group they belong to and whose BMF row does not say so - more
#' than twice what the NCCS historical extract contributed.
#'
#' The second thing it adds is **time**. The BMF is a snapshot with no notion of
#' when membership began or ended; a filing is dated. New rows therefore carry
#' `first_year`/`last_year` from the tax years the claim was actually filed in,
#' and `n_obs` counts the filings asserting it.
#'
#' @section Disagreements resolve to the BMF, on vintage:
#' The 1,782 conflicts are settled the same way `md_ingest_group_meta()` settles
#' its 1,219: the BMF is a 2026-07 snapshot and the e-file runs to 2024, so the
#' newer source wins. As there, the rule is enforced by construction - rows are
#' only written for EINs the BMF gives no GEN at all - so a conflict cannot
#' overwrite anything. The count is reported rather than absorbed.
#'
#' The 34,806 agreements are deliberately **not** written. They would duplicate
#' edges `md_ingest_relations()` already emitted, to say the same thing twice.
#' The cost is that those edges stay untimestamped; timestamping an edge owned by
#' another source is a cross-source update and does not belong in an append-only
#' ingest. Left for a compile-time join if a consumer ever needs it.
#'
#' @section Placeholder GENs are not group exemption numbers:
#' `0000` (1,352 filings), `0001` (1,291) and `9999` (315) are what filers put in
#' the box when they have nothing to put in the box. They are dropped. So is
#' anything that does not reduce to four digits.
#'
#' @section Finding the parent, and admitting when it cannot be found:
#' Membership is stored parent-to-member (§4: never a clique), so every group
#' needs a parent. Three sources are tried in order, most authoritative first:
#'
#' \enumerate{
#'   \item the BMF's own coded parent - `affiliation_code` 6 or 8, per
#'     `md_ingest_relations()`. Covers 2,504 of the 3,497 groups.
#'   \item an EIN that filed a **group return** under that GEN. A group return is
#'     filed by the central organisation, so H(a) plus H(c) is a parent claim.
#'     Covers 96 more.
#'   \item `gen_parent`, the derived GEN-to-parent table. Covers 37 more. No
#'     ingest builds it (it was made by hand in the first database), so it is
#'     used only when the table exists, and a build from scratch skips it.
#' }
#'
#' **860 groups (25%) still have no identifiable parent and produce no rows.**
#' That is reported, not patched: inventing a parent to make the join succeed
#' would fabricate the hierarchy the table exists to record.
#'
#' @param con A connection from [md_db()].
#' @param dir Directory of `F9-P00-T00-HEADER-*.CSV`.
#' @param version Pinned `efile_header` version; also names `dir` when it is `NULL`.
#' @return Row counts, invisibly.
#' @export
md_ingest_efile_group <- function(con = NULL, dir = NULL, version = "v2_2") {
  if (is.null(dir)) dir <- md_path("sources", "efile_header", version)
  glob <- file.path(dir, "F9-P00-T00-HEADER-*.CSV")
  if (!length(Sys.glob(glob))) stop("no header files under ", dir, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- paste0("efile_header-", version)
  msg <- function(...) message(sprintf(...))

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE eg AS
    SELECT 'EIN-' || substr(d,1,2) || '-' || substr(d,3,9) AS ein, gen, ty, grp
    FROM (
      SELECT lpad(regexp_replace(ORG_EIN,'[^0-9]','','g'), 9, '0') AS d,
             lpad(regexp_replace(F9_00_GROUP_EXEMPT_NUM,'[^0-9]','','g'), 4, '0') AS gen,
             try_cast(TAX_YEAR AS INT) AS ty,
             upper(coalesce(F9_00_RETURN_GROUP_X, RETURN_GROUP_X, '')) AS grp
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE)
      WHERE nullif(trim(F9_00_GROUP_EXEMPT_NUM),'') IS NOT NULL)
    WHERE gen NOT IN ('0000','0001','9999') AND length(gen) = 4",
    gsub("\\\\", "/", glob)))
  msg("  %s filings carry a usable GEN, over %s EINs and %s groups",
      format(.md_n(con, "eg"), big.mark = ","),
      format(DBI::dbGetQuery(con, "SELECT count(DISTINCT ein) n FROM eg")$n, big.mark = ","),
      format(DBI::dbGetQuery(con, "SELECT count(DISTINCT gen) n FROM eg")$n, big.mark = ","))

  agree <- DBI::dbGetQuery(con, "
    WITH u AS (SELECT DISTINCT ein, gen FROM eg)
    SELECT
      count(*) FILTER (WHERE e.group_exemption_number = u.gen) AS agrees,
      count(*) FILTER (WHERE e.group_exemption_number IS NOT NULL
                         AND e.group_exemption_number NOT IN ('','0000')
                         AND e.group_exemption_number <> u.gen) AS disagrees
    FROM u LEFT JOIN entity e ON e.ein = u.ein")
  msg("  %s pairs corroborate the BMF and are not rewritten; %s disagree and are left as the BMF has them",
      format(agree$agrees, big.mark = ","), format(agree$disagrees, big.mark = ","))

  # Parent resolution, most authoritative first. min(ein) only breaks ties
  # deterministically; it is not a seniority claim.
  #
  # gen_parent is not built by any ingest: it was made by hand in the first
  # database, so a build from scratch does not have it. Use it when present,
  # and say so when it is not, rather than fail or guess a replacement.
  gpp_sql <- if (DBI::dbExistsTable(con, "gen_parent")) {
    "SELECT gen4 AS gen, min(parent_ein2) AS ein FROM gen_parent
     WHERE parent_ein2 IS NOT NULL GROUP BY 1"
  } else {
    msg("  no gen_parent table: the third parent fallback is skipped")
    "SELECT NULL::VARCHAR AS gen, NULL::VARCHAR AS ein WHERE FALSE"
  }
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE gparent AS
    WITH g AS (SELECT DISTINCT gen FROM eg),
    bmfp AS (SELECT group_exemption_number AS gen, min(ein) AS ein FROM entity
             WHERE affiliation_code IN ('6','8')
               AND group_exemption_number IS NOT NULL
               AND group_exemption_number NOT IN ('','0000')
             GROUP BY 1),
    efp AS (SELECT gen, min(ein) AS ein FROM eg
            WHERE grp IN ('TRUE','1','X','Y') GROUP BY 1),
    gpp AS (%s)
    SELECT g.gen,
           coalesce(b.ein, f.ein, p.ein) AS parent_ein,
           CASE WHEN b.ein IS NOT NULL THEN 'bmf_affiliation_code'
                WHEN f.ein IS NOT NULL THEN 'efile_group_return_filer'
                WHEN p.ein IS NOT NULL THEN 'gen_parent_table'
                ELSE NULL END AS parent_src
    FROM g LEFT JOIN bmfp b USING (gen)
           LEFT JOIN efp  f USING (gen)
           LEFT JOIN gpp  p USING (gen)", gpp_sql))
  src <- DBI::dbGetQuery(con, "
    SELECT coalesce(parent_src,'(none)') AS parent_src, count(*) AS n
    FROM gparent GROUP BY 1 ORDER BY n DESC")
  for (i in seq_len(nrow(src))) msg("  parent from %-26s %s groups", src$parent_src[i],
                                    format(src$n[i], big.mark = ","))

  DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'efile_group'")
  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m

  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO ein_relation (%s)
    SELECT %s + row_number() OVER (), p.parent_ein, m.ein, NULL, 'group_member',
           'form990_line_H_c', 'efile_group_exemption_number', NULL,
           m.fy, m.ly, m.n, 'efile_group', '%s'
    FROM (SELECT ein, gen, min(ty) AS fy, max(ty) AS ly, count(*) AS n
          FROM eg GROUP BY ein, gen) m
    JOIN gparent p ON p.gen = m.gen AND p.parent_ein IS NOT NULL
    JOIN entity e ON e.ein = m.ein
    WHERE (e.group_exemption_number IS NULL OR e.group_exemption_number IN ('','0000'))
      AND p.parent_ein <> m.ein", .md_relation_cols(), format(base, scientific = FALSE), vintage))
  msg("  %s group_member pairs added, timestamped by filing year",
      format(n_new, big.mark = ","))

  md_record_vintage(con, "efile_header", version,
                    "ein_relation:group_member_efile", as.integer(n_new),
                    build_note = "md_ingest_efile_group(); line H(c)")
  msg("  ein_relation: %s rows", format(.md_n(con, "ein_relation"), big.mark = ","))
  invisible(stats::setNames(c(agree$agrees, agree$disagrees, n_new),
                            c("agrees", "disagrees", "added")))
}
