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

  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE grp_edge AS
    SELECT DISTINCT ein_a, ein_b
    FROM ein_relation
    WHERE relation = 'group_member'
      AND ein_a IS NOT NULL AND ein_b IS NOT NULL
      AND ein_a <> ein_b")
  n_edge <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM grp_edge")$n

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

  for (t in c("grp_edge", "grp_adj", "grp_label")) {
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
