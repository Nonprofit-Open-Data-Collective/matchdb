#' Build ein_relation from Schedule R and the group exemption structure
#'
#' Section 10 is emphatic that affiliate structure belongs in a relation table
#' rather than the name table: group subordinates and affiliate chapters are
#' *distinct EINs with near-identical names*, which is precisely the condition
#' that produces false matches. Registering "BOYS AND GIRLS CLUB OF SPRINGFIELD"
#' as an alias of the national EIN would make disambiguation worse, not better.
#'
#' matchdb's job is to record the relation with provenance. What to do with it -
#' collapse, veto, or ignore - is a matching decision and lives in `pfmatch`
#' (`R/dyads.R`, `R/affiliation.R`).
#'
#' @section Direction is fixed, not doubled:
#' A relation row reads **"`ein_b` is a `relation` of `ein_a`"**. Group rows are
#' stored once as (central, subordinate, `group_member`) rather than also as the
#' inverse `group_parent`, because storing both directions doubles the table to
#' say nothing new. Consumers that want the reverse read the pair backwards.
#'
#' @section Why group membership is not a clique:
#' 647,569 EINs carry a group exemption number, and 108 groups have more than a
#' thousand members - one has enough that a member-to-member clique would emit
#' hundreds of millions of pairs on its own. So membership is recorded as
#' parent-to-member, which is linear in group size.
#'
#' That requires identifying the parent, and the BMF `affiliation_code` does it:
#' 6 is the central organisation of a group ruling, 7 an intermediate, and 8 or 9
#' a subordinate. Groups with no coded parent produce no rows rather than a
#' guessed one, and the count of those is reported.
#'
#' @section Schedule R gives both EINs, and sometimes only one:
#' Part II lists related tax-exempt organisations with an EIN, so most rows
#' resolve to a pair. Where the EIN is absent the row is still kept, with
#' `ein_b` null and `related_name` carrying the counterparty as written -
#' resolving a name to an EIN is a *matching* problem, which is npmatch's job,
#' not something an ingest should guess at.
#'
#' @param version Pinned `efile_related` version.
#' @param con A connection from [md_db()].
#' @return Row counts, invisibly.
#' @export
md_ingest_relations <- function(version = "v2_2", con = NULL) {
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))

  if (!DBI::dbExistsTable(con, "ein_relation")) {
    DBI::dbExecute(con, "
      CREATE TABLE ein_relation (
        relation_id    BIGINT,
        ein_a          VARCHAR,
        ein_b          VARCHAR,
        related_name   VARCHAR,
        relation       VARCHAR,
        relation_raw   VARCHAR,
        evidence       VARCHAR,
        confidence     DOUBLE,
        first_year     INTEGER,
        last_year      INTEGER,
        n_obs          INTEGER,
        source         VARCHAR,
        source_vintage VARCHAR)")
  }

  ## ---- Schedule R Part II -----------------------------------------------------
  dir <- md_path("sources", "efile_related", version)
  files <- list.files(dir, pattern = "^SR-P02-T01-.*[.]CSV$", full.names = TRUE)
  n_sr <- 0L
  if (!length(files)) {
    msg("  no Schedule R files in %s - skipping the affiliate half", dir)
  } else {
    vintage <- paste0("efile_related-", version)
    DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'efile_sched_r'")
    DBI::dbExecute(con, sprintf("
      CREATE OR REPLACE TEMP TABLE sr AS
      SELECT
        EIN2 AS ein_a,
        CASE WHEN length(regexp_replace(coalesce(SR_02_RLTD_ORG_EIN,''),'[^0-9]','','g')) = 9
             THEN 'EIN-' || substr(regexp_replace(SR_02_RLTD_ORG_EIN,'[^0-9]','','g'),1,2) ||
                  '-'    || substr(regexp_replace(SR_02_RLTD_ORG_EIN,'[^0-9]','','g'),3,9)
        END AS ein_b,
        trim(coalesce(SR_02_RLTD_ORG_NAME_L1,'') || ' ' ||
             coalesce(SR_02_RLTD_ORG_NAME_L2,''))         AS related_name,
        nullif(trim(coalesce(SR_02_RLTD_ORG_PRIMARY_ACT,'')), '') AS relation_raw,
        TRY_CAST(TAX_YEAR AS INTEGER)                     AS tax_year
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE,
                         quote='\"', escape='\"')
      WHERE EIN2 IS NOT NULL AND regexp_matches(EIN2,'^EIN-[0-9]{2}-[0-9]{7}$')",
      file.path(dir, "SR-P02-T01-*.CSV")))

    base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m
    n_sr <- DBI::dbExecute(con, sprintf("
      INSERT INTO ein_relation
      SELECT %s + row_number() OVER (), ein_a, ein_b, related_name, 'affiliate',
             relation_raw, 'schedule_r_part_ii', NULL,
             first_year, last_year, n_obs, 'efile_sched_r', '%s'
      FROM (
        SELECT ein_a, ein_b,
               max(related_name) AS related_name,
               max(relation_raw) AS relation_raw,
               min(tax_year) AS first_year, max(tax_year) AS last_year,
               count(*) AS n_obs
        FROM sr
        WHERE ein_b IS NOT NULL OR trim(related_name) <> ''
        GROUP BY ein_a, ein_b)",
      format(base, scientific = FALSE), vintage))

    unresolved <- DBI::dbGetQuery(con, "
      SELECT count(*) AS n FROM ein_relation
      WHERE source = 'efile_sched_r' AND ein_b IS NULL")$n
    msg("  Schedule R: %s affiliate pairs, %s with no counterparty EIN",
        format(n_sr, big.mark = ","), format(unresolved, big.mark = ","))
    md_record_vintage(con, "efile_related", version, "ein_relation:affiliate",
                      as.integer(n_sr), build_note = "md_ingest_relations()")
  }

  ## ---- group exemption --------------------------------------------------------
  DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'bmf_gen'")
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE gen AS
    SELECT ein, group_exemption_number AS gen, affiliation_code
    FROM entity
    WHERE group_exemption_number IS NOT NULL
      AND group_exemption_number NOT IN ('', '0000')")

  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m
  n_gen <- DBI::dbExecute(con, sprintf("
    INSERT INTO ein_relation
    SELECT %s + row_number() OVER (), p.ein, m.ein, NULL, 'group_member',
           'affiliation_code=' || coalesce(m.affiliation_code,'?'),
           'bmf_group_exemption', NULL, NULL, NULL, NULL,
           'bmf_gen', 'bmf_unified-v2026-08-11'
    FROM gen p JOIN gen m ON p.gen = m.gen AND p.ein <> m.ein
    WHERE p.affiliation_code = '6'
      AND m.affiliation_code IN ('7','8','9')",
    format(base, scientific = FALSE)))

  orphan <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM (
      SELECT gen FROM gen GROUP BY gen
      HAVING sum(CASE WHEN affiliation_code = '6' THEN 1 ELSE 0 END) = 0)")$n
  msg("  group exemption: %s parent-to-member pairs; %s groups have no coded parent",
      format(n_gen, big.mark = ","), format(orphan, big.mark = ","))
  md_record_vintage(con, "bmf_unified", "v2026-08-11", "ein_relation:group_member",
                    as.integer(n_gen), build_note = "md_ingest_relations()")

  total <- .md_n(con, "ein_relation")
  msg("  ein_relation: %s rows", format(total, big.mark = ","))
  invisible(stats::setNames(c(n_sr, n_gen, total),
                            c("affiliate", "group_member", "total")))
}

#' @rdname md_layers
#' @export
md_relations <- function() {
  c("group_parent", "group_member", "affiliate", "dyad_substitutable", "successor")
}
