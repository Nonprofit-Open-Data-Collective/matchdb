#' Add the Schedule C affiliated-group roster
#'
#' An organisation that has made the §501(h) lobbying election and belongs to an
#' affiliated group must list, in Schedule C Part II-A, every member of that
#' group with name, address, EIN, expenses and share of excess lobbying
#' expenditures. `AffiliatedGroupSchedule/AffiliatedScheduleGrp` in the XML.
#'
#' @section It is a different concept from group exemption, and must stay one:
#' A §501(h) affiliated group is defined by interlocking governance under §4911 -
#' one organisation controlling another's lobbying decisions. That is not the
#' group exemption process, and these edges must never enter the `group_id`
#' components (`GROUP-STRUCTURE-FINDINGS.md` §2). They land as `affiliate`, the
#' same relation Schedule R Part II uses.
#'
#' @section It is reciprocal, which is why the self-loops matter:
#' Every electing member reports the *whole* group, so a five-member group
#' produces five rosters that each name all five. In TY2013, **78 of 123 filers
#' list their own EIN**, and 652 rows collapse to 339 distinct member EINs.
#' Self-references are dropped; the rest are stored in the disclosed direction
#' (filer -> member) like every other relation, and a consumer wanting the
#' undirected view reads the pair both ways.
#'
#' @section It is nearly redundant, and is loaded anyway for the provenance:
#' Measured on TY2013, **394 of 430 undirected pairs (91.6%) already exist as
#' Schedule R Part II edges**. This source adds tens of pairs, not thousands.
#'
#' It earns its place on the `evidence` tag rather than the coverage: an edge
#' corroborated by both a Schedule R disclosure and a §501(h) affiliated-group
#' filing is a stronger claim than either alone, and only this ingest can say so.
#' Loading it to inflate the row count would be the wrong reason.
#'
#' @section There is no published table, and the element was renamed in 2013:
#' Like `AffiliateListing`, this has no `RDB_TABLE` in the NCCS concordance, so
#' it comes from a local extract of raw XML. Through TY2012 the element is
#' `AffiliatedGroupSchedule/AffiliatedSchedule` with `AddressUS/`; from TY2013 it
#' is `AffiliatedScheduleGrp` with `USAddress/`. The extract matches on field
#' suffix to serve both.
#'
#' \preformatted{
#'   2009  355 rows /  58 filings
#'   2010  543 rows /  90 filings
#'   2011  554 rows /  98 filings
#'   2012  761 rows / 117 filings
#'   2013  652 rows / 123 filings
#'   ---------------------------------
#'        2,865 rows / 486 filings / 459 distinct member EINs
#' }
#'
#' @param con A connection from [md_db()].
#' @param path Path to the derived `sched-c-affiliated-group-*.csv`.
#' @return Row counts, invisibly.
#' @export
md_ingest_sched_c_affil <- function(con = NULL, path = NULL) {
  if (is.null(path)) {
    path <- md_path("sources", "efile_sched_c_affil", "v2009-2013",
                    "sched-c-affiliated-group-2009-2013.csv")
  }
  if (!file.exists(path)) stop("no Schedule C extract at ", path, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- "efile_sched_c_affil-v2009-2013"
  msg <- function(...) message(sprintf(...))

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE scaf AS
    SELECT 'EIN-' || substr(fd,1,2) || '-' || substr(fd,3,9) AS ein_a,
           'EIN-' || substr(md,1,2) || '-' || substr(md,3,9) AS ein_b,
           nm, ty, self
    FROM (
      SELECT lpad(regexp_replace(filer_ein, '[^0-9]','','g'), 9, '0') AS fd,
             lpad(regexp_replace(member_ein,'[^0-9]','','g'), 9, '0') AS md,
             nullif(trim(member_name1),'') AS nm,
             try_cast(tax_year AS INT) AS ty,
             (lpad(regexp_replace(filer_ein,'[^0-9]','','g'),9,'0') =
              lpad(regexp_replace(member_ein,'[^0-9]','','g'),9,'0')) AS self
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE)
      WHERE length(regexp_replace(member_ein,'[^0-9]','','g')) = 9
        AND length(regexp_replace(filer_ein, '[^0-9]','','g')) = 9)",
    gsub("\\\\", "/", path)))
  n_self <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM scaf WHERE self")$n
  msg("  %s roster rows, of which %s are self-references and are dropped",
      format(.md_n(con, "scaf"), big.mark = ","), format(n_self, big.mark = ","))

  DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'efile_sched_c'")
  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m
  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO ein_relation
    SELECT %s + row_number() OVER (), ein_a, ein_b, nm, 'affiliate',
           'AffiliatedScheduleGrp', 'schedule_c_part_ii_a', NULL,
           fy, ly, n, 'efile_sched_c', '%s'
    FROM (SELECT ein_a, ein_b, max(nm) AS nm, min(ty) AS fy, max(ty) AS ly,
                 count(*) AS n
          FROM scaf WHERE NOT self GROUP BY ein_a, ein_b)",
    format(base, scientific = FALSE), vintage))
  msg("  %s affiliate edges added", format(n_new, big.mark = ","))

  dup <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM (SELECT DISTINCT ein_a, ein_b FROM scaf WHERE NOT self) s
    WHERE EXISTS (SELECT 1 FROM ein_relation r
                  WHERE r.source = 'efile_sched_r' AND r.relation = 'affiliate'
                    AND ((r.ein_a = s.ein_a AND r.ein_b = s.ein_b)
                      OR (r.ein_a = s.ein_b AND r.ein_b = s.ein_a)))")$n
  msg("  %s of them are corroborations of a Schedule R Part II edge", format(dup, big.mark = ","))

  md_record_vintage(con, "efile_sched_c_affil", "v2009-2013",
                    "ein_relation:affiliate", as.integer(n_new),
                    build_note = "md_ingest_sched_c_affil(); 501(h) affiliated group")
  msg("  ein_relation: %s rows", format(.md_n(con, "ein_relation"), big.mark = ","))
  invisible(stats::setNames(c(n_self, n_new, dup), c("self_refs", "added", "corroborations")))
}
