#' Add group-return rosters: the subordinate names the BMF throws away
#'
#' When a central organisation files a group return it attaches a roster naming
#' every subordinate covered - `AffiliateListing/AffiliateListingGrp` in the XML,
#' with name, EIN and address for each. It is the only source that states a
#' group's membership as a list rather than leaving it to be inferred from a
#' shared GEN.
#'
#' @section This is the source that recovers subordinate names:
#' `GROUP-STRUCTURE-FINDINGS.md` §4 measured the problem: the BMF assigns most
#' subordinates the **parent's** legal name. Of 1,068 TY2013 affiliates matched
#' to the BMF, **803 (75.2%)** carry a BMF name different from the one they
#' report for themselves, and in 70% of group returns *every* member shares one
#' identical BMF name. Five Einstein subordinates all read
#' "ALBERT EINSTEIN HEALTHCARE NETWORK" in the BMF while calling themselves
#' "Belmont Center For Comprehensive Tr", "Einstein Practice Plan Inc" and so on.
#'
#' So a subordinate's own name is usually **absent from the reference entirely**,
#' and this roster is where it lives. In a held-out retrieval test (§5) these
#' tokens were 0.19% of the index and carried 23% of the gain - the best return
#' per row measured anywhere in that work.
#'
#' The names therefore land as `observed` variants on the subordinates' **own**
#' EINs. That is the narrow §10 exception, not a breach of it: the roster states
#' the subordinate's own name, not the parent's, so registering it aliases
#' nothing. The parent's name is never copied onto a member.
#'
#' @section There is no published table for this:
#' Unlike Schedule R Part II, `AffiliateListing` has **no `RDB_TABLE`** in the
#' NCCS concordance, so no CSV exists to download. It is reachable only from raw
#' XML or the `EFILE20xx.duckdb` extracts, and the CSV this function reads is a
#' derived extract produced from those. It is pinned like any other source, but
#' its provenance is a local extraction rather than an upstream URL.
#'
#' @section The element was renamed in 2013:
#' Returns through TY2012 use `AffiliateListing/Affiliate` with `Name/`,
#' `AddressUS/` and `NameControl`; TY2013 onward uses
#' `AffiliateListing/AffiliateListingGrp` with `BusinessName/`, `USAddress/` and
#' `BusinessNameControlTxt`. The extract normalises both by matching on the field
#' suffix. A run that returns rows for 2013 only has silently hit the rename.
#'
#' \preformatted{
#'   2009    260 rows /  21 filings
#'   2010  1,630 rows /  66 filings
#'   2011  1,276 rows /  79 filings
#'   2012  1,204 rows /  88 filings
#'   2013  1,070 rows /  99 filings
#'   ----------------------------------
#'          5,440 rows / 353 filings / 2,515 distinct subordinate EINs
#' }
#'
#' Coverage is thin by construction: only 99 of 483 TY2013 group filers itemise
#' members at all. This source is precise, not comprehensive.
#'
#' @section Direction and self-references:
#' The filer of a group return is the central organisation, so the edge is
#' (filer, member, `group_member`) - the same direction as every other group
#' source. Rows where a filer lists its own EIN are self-loops and are dropped.
#'
#' @param con A connection from [md_db()].
#' @param path Path to the derived `affiliate-listing-*.csv`.
#' @param guard Run [md_guard_observed()] on the observed rows of source `efile990`.
#' @return Row counts, invisibly.
#' @export
md_ingest_affiliate_listing <- function(con = NULL, path = NULL, guard = TRUE) {
  if (is.null(path)) {
    path <- md_path("sources", "efile_affiliate_listing", "v2009-2013",
                    "affiliate-listing-2009-2013.csv")
  }
  if (!file.exists(path)) stop("no affiliate listing extract at ", path, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- "efile_affiliate_listing-v2009-2013"
  msg <- function(...) message(sprintf(...))

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE afl AS
    SELECT
      'EIN-' || substr(pd,1,2) || '-' || substr(pd,3,9) AS parent_ein,
      'EIN-' || substr(md,1,2) || '-' || substr(md,3,9) AS member_ein,
      nm1, nm2, ty
    FROM (
      SELECT lpad(regexp_replace(filer_ein, '[^0-9]','','g'), 9, '0')  AS pd,
             lpad(regexp_replace(member_ein,'[^0-9]','','g'), 9, '0')  AS md,
             nullif(trim(member_name1),'') AS nm1,
             nullif(trim(member_name2),'') AS nm2,
             try_cast(tax_year AS INT)     AS ty
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE)
      WHERE length(regexp_replace(member_ein,'[^0-9]','','g')) = 9
        AND length(regexp_replace(filer_ein, '[^0-9]','','g')) = 9)
    WHERE pd <> md", gsub("\\\\", "/", path)))
  msg("  %s roster rows over %s subordinate EINs",
      format(.md_n(con, "afl"), big.mark = ","),
      format(DBI::dbGetQuery(con, "SELECT count(DISTINCT member_ein) n FROM afl")$n,
             big.mark = ","))

  ## ---- group_member edges ------------------------------------------------------
  DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'efile_afl'")
  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m
  n_rel <- DBI::dbExecute(con, sprintf("
    INSERT INTO ein_relation (%s)
    SELECT %s + row_number() OVER (), parent_ein, member_ein, nm, 'group_member',
           'AffiliateListingGrp', 'efile_affiliate_listing', NULL,
           fy, ly, n, 'efile_afl', '%s'
    FROM (SELECT parent_ein, member_ein, max(nm1) AS nm,
                 min(ty) AS fy, max(ty) AS ly, count(*) AS n
          FROM afl GROUP BY parent_ein, member_ein)",
    .md_relation_cols(), format(base, scientific = FALSE), vintage))
  msg("  %s group_member edges added", format(n_rel, big.mark = ","))

  novel <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM (SELECT DISTINCT parent_ein, member_ein FROM afl) a
    WHERE NOT EXISTS (SELECT 1 FROM ein_relation r
                      WHERE r.source <> 'efile_afl' AND r.relation = 'group_member'
                        AND r.ein_a = a.parent_ein AND r.ein_b = a.member_ein)")$n
  msg("  of those, %s are pairs no other group source asserts", format(novel, big.mark = ","))

  ## ---- observed names on the subordinate's own EIN -----------------------------
  DBI::dbExecute(con, sprintf("DELETE FROM name WHERE source_vintage = '%s'", vintage))
  nbase <- DBI::dbGetQuery(con, "SELECT coalesce(max(name_id),0) AS m FROM name")$m
  .md_name_guard_columns(con)
  n_nm <-DBI::dbExecute(con, sprintf("
    INSERT INTO name (name_id, ein, name_raw, variant_class, source,
                      source_vintage, n_obs, n_corroborators)
    SELECT %s + row_number() OVER (), ein, nm, 'observed', 'efile990', '%s',
           n_obs, n_corr
    FROM (
      SELECT member_ein AS ein,
             trim(nm1 || coalesce(' ' || nm2, '')) AS nm,
             count(*) AS n_obs, count(DISTINCT parent_ein) AS n_corr
      FROM afl WHERE nm1 IS NOT NULL
      GROUP BY member_ein, trim(nm1 || coalesce(' ' || nm2, '')))",
    format(nbase, scientific = FALSE), vintage))
  msg("  %s observed names written to the subordinates' own EINs", format(n_nm, big.mark = ","))

  unknown <- DBI::dbGetQuery(con, "
    SELECT count(DISTINCT member_ein) AS n FROM afl a
    WHERE NOT EXISTS (SELECT 1 FROM entity e WHERE e.ein = a.member_ein)")$n
  msg("  %s subordinate EINs are not in `entity` at all", format(unknown, big.mark = ","))

  md_record_vintage(con, "efile_affiliate_listing", "v2009-2013",
                    "ein_relation:group_member", as.integer(n_rel),
                    build_note = "md_ingest_affiliate_listing()")
  md_record_vintage(con, "efile_affiliate_listing", "v2009-2013",
                    "name:observed", as.integer(n_nm),
                    build_note = "md_ingest_affiliate_listing(); subordinate self-reported names")
  msg("  ein_relation: %s rows | name: %s rows",
      format(.md_n(con, "ein_relation"), big.mark = ","),
      format(.md_n(con, "name"), big.mark = ","))
  # Placeholder EINs and names, and names unlike the member's own, are flagged
  # here as on Schedule I. Own-EIN rows were dropped above (self-loops), and the
  # fiscal-sponsor test reads Schedule I only.
  if (guard) md_guard_observed(con, sources = "efile990")
  invisible(stats::setNames(c(n_rel, novel, n_nm), c("edges", "novel_edges", "names")))
}
