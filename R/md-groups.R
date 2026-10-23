#' Build `group_id`: the federated families in `ein_relation`
#'
#' Takes the connected components of the `group_member` edges in
#' `ein_relation` and stores one row per EIN that belongs to a group, as the
#' derived table `entity_group`. Two EINs are in the same family exactly when
#' they share a `group_id`, so the question `pfmatch/R/dyads.R` recomputes per
#' query - *are these two candidates the same family?* - becomes one join.
#'
#' This is the `cluster_id` of `REDUCTION.md` section 6a, under the name the
#' schema uses (`PLAN.md` section 4, `GROUP-STRUCTURE-FINDINGS.md` section 1).
#'
#' @section Only `group_member` edges:
#' `related_entity` and `disregarded_entity` edges never enter the components.
#' Unioned in, they join the health-system and university sectors into one
#' component of 117,869 EINs (`RELATION-BUILD-PLAN.md`). Those edges will feed a
#' separate `related_entity_id`, which needs its own guard. Edges with no
#' counterparty EIN (`ein_b` NULL) and self-loops are skipped.
#'
#' @section Why components, not the GEN:
#' A group exemption number cannot be the key: one logical group already spans
#' several GENs (Lions 4, AAU 7, 4-H 12), and Rev. Proc. 2026-8 makes central
#' organisations drop all but one ruling by 2027-01-22. A central EIN holding
#' several GENs links them all, and a member listed under two parents joins
#' their groups, which a GEN key would miss.
#'
#' @section One bad edge joins two families, so evidence is ranked:
#' Connected components are only as good as the weakest edge: a single member
#' listed under two parents joins their groups. In the first full build that
#' happened through self-reported evidence. A filer writes another group's GEN
#' on line H(c), by typo or from an old ruling, and a high-school orchestra
#' became a member of both a youth soccer league and Parent Booster USA. The
#' result was one component of 25,739 EINs joining the US Catholic Conference,
#' the Mayo Clinic, a sorority and a motorcycle club.
#'
#' So each member's edges are filtered before the components are taken. Only
#' its best-ranked evidence counts, in this order:
#'
#' \enumerate{
#'   \item `bmf_group_exemption` - the IRS's own coding.
#'   \item `efile_affiliate_listing` - the parent's own roster on its group return.
#'   \item `nccs_group_metadata_historical` - an older GEN assignment.
#'   \item `efile_group_exemption_number` - the member's own line H(c).
#'   \item anything else.
#' }
#'
#' The first two are kept whole: a member the IRS or its parent places in two
#' groups is a real link. From the self-reported ranks a member keeps one
#' parent, the one it reported in the most filings (then the latest, then the
#' smallest EIN). The set-aside edges stay in `ein_relation`; only the
#' components ignore them.
#'
#' @section How `group_id` is named:
#' `group_id` is `"GRP-"` followed by the digits of the smallest EIN in the
#' component, e.g. `GRP-01-0347504`. It depends only on the component's
#' membership, so rebuilding gives the same ids, and adding an unrelated group
#' moves no existing one - unlike a row number. It carries no other meaning:
#' the smallest EIN is often a member, not the parent. Use `group_central_ein`
#' for the parent.
#'
#' @section Columns:
#' \describe{
#'   \item{`ein`}{an EIN that appears in at least one `group_member` edge}
#'   \item{`group_id`}{the family, as above}
#'   \item{`group_size`}{EINs in the component}
#'   \item{`role`}{`parent` (only ever `ein_a`), `member` (only ever `ein_b`),
#'     or `both` - an EIN that is a parent in one edge and a member in another}
#'   \item{`n_parents`}{distinct parents this EIN is a member of; above 1 is
#'     what joins two stars into one family}
#'   \item{`group_central_ein`}{the parent with the most members in the
#'     component; ties go to the smallest EIN}
#' }
#'
#' EINs in no group get no row. A `LEFT JOIN` from `entity` gives them `NULL`.
#'
#' @section Rebuild after any relation ingest:
#' Like [md_build_compact()], this drops and rebuilds. It reads only
#' `ein_relation`, keyed on EIN rather than on reassigned row ids, so a
#' re-ingest leaves it out of date rather than broken. Rebuild it after any
#' ingest that writes `group_member` edges.
#'
#' @param con A connection from [md_db()].
#' @param max_iter Upper bound on label-propagation passes. Each pass moves the
#'   smallest EIN at least one hop, so this bounds the longest path in a
#'   component. The real edges converge in a handful; reaching the bound is an
#'   error, not a silent partial answer.
#' @return Invisibly, a one-row data frame: edges, EINs, groups, the largest
#'   and median group size, and the passes taken.
#' @export
md_build_groups <- function(con = NULL, max_iter = 100L) {
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))

  if (!DBI::dbExistsTable(con, "ein_relation")) {
    stop("ein_relation does not exist - run the relation ingests first",
         call. = FALSE)
  }

  # One member's edges: only its best-ranked evidence, and from self-reported
  # evidence only its most-reported parent (see the section on bridges).
  flds <- DBI::dbListFields(con, "ein_relation")
  col <- function(f, default) if (f %in% flds) f else default
  rank_case <- paste0("CASE ", col("evidence", "NULL"), " ",
    paste(sprintf("WHEN '%s' THEN %d", names(.md_group_evidence_rank),
                  .md_group_evidence_rank), collapse = " "),
    " ELSE ", if ("evidence" %in% flds) length(.md_group_evidence_rank) + 1L else 1L,
    " END")
  .md_placeholder_macro(con)
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE grp_edge_all AS
    SELECT ein_a, ein_b, %s AS rk,
           coalesce(%s, 0) AS n_obs, coalesce(%s, 0) AS last_year
    FROM ein_relation
    WHERE relation = 'group_member'
      AND ein_a IS NOT NULL AND ein_b IS NOT NULL
      AND ein_a <> ein_b
      AND NOT md_placeholder_ein(ein_a) AND NOT md_placeholder_ein(ein_b)",
    rank_case, col("n_obs", "NULL"), col("last_year", "NULL")))
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE grp_edge AS
    WITH best AS (SELECT ein_b, min(rk) AS rk FROM grp_edge_all GROUP BY 1),
    kept AS (
      SELECT e.ein_a, e.ein_b, e.rk, sum(e.n_obs) AS n_obs, max(e.last_year) AS ly
      FROM grp_edge_all e JOIN best b ON b.ein_b = e.ein_b AND b.rk = e.rk
      GROUP BY 1, 2, 3
    ), pick AS (
      SELECT *, row_number() OVER (PARTITION BY ein_b
                                   ORDER BY n_obs DESC, ly DESC, ein_a) AS pk
      FROM kept
    )
    SELECT DISTINCT ein_a, ein_b FROM pick
    WHERE rk <= %d OR pk = 1",
    .md_group_curated_rank))
  n_all <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM (SELECT DISTINCT ein_a, ein_b FROM grp_edge_all)")$n
  n_edge <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM grp_edge")$n
  msg("group_member edges: %s, of which %s are used and %s set aside as weaker evidence for a member that has better",
      format(n_all, big.mark = ","), format(n_edge, big.mark = ","),
      format(n_all - n_edge, big.mark = ","))

  # Undirected adjacency, and every node labelled with itself.
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE grp_adj AS
    SELECT ein_a AS ein, ein_b AS nbr FROM grp_edge
    UNION ALL
    SELECT ein_b, ein_a FROM grp_edge")
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE grp_label AS
    SELECT DISTINCT ein, ein AS label FROM grp_adj")

  # Min-label propagation: each pass, every EIN takes the smallest label among
  # itself and its neighbours. Stops when a pass changes nothing.
  iter <- 0L
  repeat {
    iter <- iter + 1L
    if (iter > max_iter) {
      stop(sprintf(
        "group components did not converge in %d passes - raise max_iter, or look for an unexpectedly long chain of group_member edges",
        max_iter), call. = FALSE)
    }
    DBI::dbExecute(con, "
      CREATE OR REPLACE TEMP TABLE grp_next AS
      SELECT l.ein, least(l.label, coalesce(min(n.label), l.label)) AS label
      FROM grp_label l
      LEFT JOIN grp_adj a ON a.ein = l.ein
      LEFT JOIN grp_label n ON n.ein = a.nbr
      GROUP BY l.ein, l.label")
    changed <- DBI::dbGetQuery(con, "
      SELECT count(*) AS n FROM grp_next x JOIN grp_label l USING (ein)
      WHERE x.label <> l.label")$n
    DBI::dbExecute(con, "DROP TABLE grp_label")
    DBI::dbExecute(con, "ALTER TABLE grp_next RENAME TO grp_label")
    if (changed == 0) break
  }

  DBI::dbExecute(con, "DROP TABLE IF EXISTS entity_group")
  DBI::dbExecute(con, "
    CREATE TABLE entity_group AS
    WITH roles AS (
      SELECT ein,
             bool_or(is_parent) AS as_parent,
             bool_or(NOT is_parent) AS as_member
      FROM (SELECT ein_a AS ein, TRUE AS is_parent FROM grp_edge
            UNION ALL
            SELECT ein_b, FALSE FROM grp_edge)
      GROUP BY ein
    ), parents AS (
      SELECT ein_b AS ein, count(DISTINCT ein_a) AS n_parents
      FROM grp_edge GROUP BY ein_b
    ), fanout AS (
      SELECT ein_a AS ein, count(DISTINCT ein_b) AS n_members
      FROM grp_edge GROUP BY ein_a
    ), central AS (
      SELECT label, ein AS group_central_ein FROM (
        SELECT l.label, l.ein,
               row_number() OVER (PARTITION BY l.label
                                  ORDER BY f.n_members DESC, l.ein) AS rk
        FROM grp_label l JOIN fanout f USING (ein))
      WHERE rk = 1
    )
    SELECT l.ein,
           'GRP-' || substr(l.label, 5) AS group_id,
           count(*) OVER (PARTITION BY l.label) AS group_size,
           CASE WHEN r.as_parent AND r.as_member THEN 'both'
                WHEN r.as_parent THEN 'parent' ELSE 'member' END AS role,
           coalesce(p.n_parents, 0) AS n_parents,
           c.group_central_ein
    FROM grp_label l
    JOIN roles r USING (ein)
    LEFT JOIN parents p USING (ein)
    LEFT JOIN central c USING (label)
    ORDER BY group_id, ein")

  for (t in c("grp_edge_all", "grp_edge", "grp_adj", "grp_label")) {
    DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s", t))
  }

  out <- DBI::dbGetQuery(con, "
    SELECT count(*) AS eins,
           count(DISTINCT group_id) AS groups
    FROM entity_group")
  sizes <- DBI::dbGetQuery(con, "
    SELECT group_size FROM entity_group GROUP BY group_id, group_size")$group_size
  out <- data.frame(edges = n_edge, eins = out$eins, groups = out$groups,
                    largest = if (length(sizes)) max(sizes) else 0L,
                    median = if (length(sizes)) stats::median(sizes) else 0,
                    passes = iter)
  msg("entity_group: %s EINs in %s groups from %s group_member edges (%d passes)",
      format(out$eins, big.mark = ","), format(out$groups, big.mark = ","),
      format(out$edges, big.mark = ","), iter)
  msg("  group size: median %s, largest %s",
      format(out$median, big.mark = ","), format(out$largest, big.mark = ","))
  invisible(out)
}

# Evidence for a group_member edge, most authoritative first. Ranks up to
# .md_group_curated_rank are kept whole; above it a member keeps one parent.
.md_group_evidence_rank <- c(
  bmf_group_exemption            = 1L,
  efile_affiliate_listing        = 2L,
  nccs_group_metadata_historical = 3L,
  efile_group_exemption_number   = 4L)
.md_group_curated_rank <- 2L
