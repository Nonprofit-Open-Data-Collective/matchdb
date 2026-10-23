#' Everything the database knows about an EIN
#'
#' `md_lookup()` gathers, for one or more EINs, the rows every table holds:
#' the entity record, every observed name and address with its source, dated
#' events (990-N terminations, revocations), relations disclosed in either
#' direction, cluster memberships, shared identifiers and websites. It is the
#' read side of the database for a person, not for a matcher; to build a
#' reference for matching use [md_spec()] and [md_compile()].
#'
#' @section What is left out by default:
#' Part VII officer keys (`ein_key` rows of kind `person`) are derived from
#' people's names. They are left out unless `include_people = TRUE`. Mission
#' and program text is large and is left out unless `"orgtext"` is in `parts`.
#'
#' @param ein One or more EINs, in any form [md_ein()] accepts.
#' @param parts Which parts to return. The default is every part except
#'   `"orgtext"`.
#' @param include_people Include officer name keys among the shared keys.
#' @param con A connection from [md_db()]; opened read-only and closed when
#'   `NULL`.
#' @return An `md_lookup`: a named list of data frames, one per part, each with
#'   an `ein` column. Parts whose table is not in the database are absent.
#' @examples
#' \dontrun{
#' x <- md_lookup("53-0196605")
#' x
#' x$names
#' }
#' @export
md_lookup <- function(ein, parts = md_lookup_parts(), include_people = FALSE, con = NULL) {
  eins <- unique(md_ein(ein))
  bad <- setdiff(parts, c(md_lookup_parts(), "orgtext"))
  if (length(bad)) stop("unknown part(s): ", paste(bad, collapse = ", "), call. = FALSE)
  if (is.null(con)) { con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE) }
  tabs <- DBI::dbListTables(con)
  duckdb::duckdb_register(con, "lk_ein", data.frame(ein = eins, stringsAsFactors = FALSE))
  on.exit(duckdb::duckdb_unregister(con, "lk_ein"), add = TRUE, after = FALSE)
  q <- function(sql) DBI::dbGetQuery(con, sql)
  has <- function(...) all(c(...) %in% tabs)

  out <- list()
  if ("entity" %in% parts && has("entity")) {
    out$entity <- q("SELECT e.* FROM entity e JOIN lk_ein USING (ein) ORDER BY ein")
  }
  # columns a table has, of those wanted: older builds and small test
  # databases carry fewer
  pick <- function(table, alias, wanted) {
    have <- intersect(wanted, .md_cols(con, table))
    paste(sprintf("%s.%s", alias, have), collapse = ", ")
  }
  ord <- function(table, alias, cols) {
    have <- intersect(sub(" .*", "", cols), .md_cols(con, table))
    o <- cols[sub(" .*", "", cols) %in% have]
    if (length(o)) paste0(", ", paste(sprintf("%s.%s", alias, o), collapse = ", ")) else ""
  }
  if ("names" %in% parts && has("name")) {
    key <- if (has("name_derived")) "d.name_key" else "NULL"
    jn <- if (has("name_derived"))
      "LEFT JOIN name_derived d ON CAST(d.name_id AS BIGINT) = n.name_id" else ""
    out$names <- q(sprintf("
      SELECT n.ein, n.name_raw, %s AS name_key, %s
      FROM name n JOIN lk_ein USING (ein) %s
      ORDER BY n.ein, %s, CASE WHEN n.source = 'bmf' THEN 0 ELSE 1 END%s, n.name_raw", key,
      pick("name", "n", c("variant_class", "source", "n_obs", "n_corroborators", "first_year",
                          "last_year", "name_id")),
      jn, .md_class_order_sql("n.variant_class"),
      ord("name", "n", c("n_corroborators DESC NULLS LAST", "n_obs DESC NULLS LAST"))))
  }
  if ("addresses" %in% parts && has("address")) {
    out$addresses <- q(sprintf("
      SELECT a.ein, %s, n.name_raw AS observed_as
      FROM address a JOIN lk_ein USING (ein)
      LEFT JOIN name n ON n.name_id = a.name_id
      ORDER BY a.ein, %s%s, a.street_raw",
      pick("address", "a", c("street_raw", "city_raw", "state", "zip5", "variant_class",
                             "source", "n_obs", "first_vintage", "last_vintage")),
      .md_class_order_sql("a.variant_class"),
      ord("address", "a", "last_vintage DESC NULLS LAST")))
  }
  if ("events" %in% parts && has("entity_event")) {
    out$events <- q("SELECT v.* FROM entity_event v JOIN lk_ein USING (ein)
                     ORDER BY ein, event_date NULLS LAST, event")
  }
  if ("relations" %in% parts && has("ein_relation")) {
    out$relations <- q("
      SELECT l.ein, CASE WHEN r.ein_a = l.ein THEN r.ein_b ELSE r.ein_a END AS other_ein,
             CASE WHEN r.ein_a = l.ein THEN 'discloses' ELSE 'disclosed_by' END AS direction,
             r.relation, r.related_name, r.evidence, r.source, r.first_year, r.last_year, r.n_obs
      FROM ein_relation r JOIN lk_ein l ON l.ein = r.ein_a OR l.ein = r.ein_b
      ORDER BY l.ein, r.relation, other_ein")
  }
  if ("clusters" %in% parts && has("cluster", "cluster_member")) {
    cc <- .md_cols(con, "cluster"); mc <- .md_cols(con, "cluster_member")
    opt <- c(if ("role" %in% mc) "m.role", if ("size" %in% cc) "c.size",
             if ("label" %in% cc) "c.label")
    out$clusters <- q(sprintf("
      SELECT m.ein, m.cluster_id, c.cluster_type%s
      FROM cluster_member m JOIN lk_ein USING (ein) JOIN cluster c USING (cluster_id)
      ORDER BY m.ein, c.cluster_type, m.cluster_id",
      .md_extra_cols(opt)))
  }
  if ("keys" %in% parts && has("ein_key")) {
    out$keys <- q(sprintf("
      SELECT k.* FROM ein_key k JOIN lk_ein USING (ein) WHERE %s
      ORDER BY ein, kind, n_eins_sharing, key",
      if (include_people) "TRUE" else "k.kind <> 'person'"))
  }
  if ("websites" %in% parts && has("website")) {
    out$websites <- q(sprintf("SELECT w.ein, %s FROM website w JOIN lk_ein USING (ein)
                               ORDER BY w.ein%s, w.url",
      pick("website", "w", c("url", "site_key", "host", "kind", "is_platform", "source",
                             "n_obs", "first_year", "last_year", "n_eins_sharing")),
      ord("website", "w", "n_obs DESC NULLS LAST")))
  }
  if ("orgtext" %in% parts && has("orgtext")) {
    out$orgtext <- q("SELECT t.* FROM orgtext t JOIN lk_ein USING (ein)
                      ORDER BY ein, tax_year DESC, text_kind")
  }
  for (p in names(out)) rownames(out[[p]]) <- NULL
  structure(out, eins = eins, class = "md_lookup")
}

#' @rdname md_lookup
#' @export
md_lookup_parts <- function() {
  c("entity", "names", "addresses", "events", "relations", "clusters", "keys", "websites")
}

#' @export
print.md_lookup <- function(x, n = 5L, ...) {
  for (e in attr(x, "eins")) {
    ent <- x$entity[x$entity$ein == e, , drop = FALSE]
    nm <- x$names[x$names$ein == e, , drop = FALSE]
    legal <- nm$name_raw[nm$variant_class == "legal"][1]
    cat(sprintf("<md_lookup> %s  %s\n", e, if (is.na(legal %||% NA)) "" else legal))
    if (!nrow(ent)) { cat("  not in entity\n\n"); next }
    cat(sprintf("  layer %s, active %s, NTEE %s, subsection %s\n", ent$layer[1],
                ent$active[1], ent$ntee_code[1] %||% NA, ent$subsection[1] %||% NA))
    for (p in setdiff(names(x), "entity")) {
      d <- x[[p]][x[[p]]$ein == e, , drop = FALSE]
      cat(sprintf("  %-10s %d row%s", p, nrow(d), if (nrow(d) == 1) "" else "s"))
      if (p == "names" && nrow(d)) {
        tb <- table(d$variant_class)
        cat(" (", paste(names(tb), tb, sep = " ", collapse = ", "), ")", sep = "")
      }
      if (p == "clusters" && nrow(d)) {
        tb <- table(d$cluster_type)
        cat(" (", paste(names(tb), tb, sep = " ", collapse = ", "), ")", sep = "")
      }
      cat("\n")
    }
    if (nrow(nm)) {
      cat("  names:\n")
      s <- utils::head(nm, n)
      cat(sprintf("    %-11s %-45s %s\n", s$variant_class, substr(s$name_raw, 1, 45), s$source),
          sep = "")
    }
    cat("\n")
  }
  invisible(x)
}

#' The families an EIN belongs to, and who else is in them
#'
#' matchdb groups EINs into typed clusters, an EIN may sit in several:
#' `group_exemption` (an IRS group ruling), `related_system` (Schedule R),
#' `care_of_network` (a shared in-care-of organisation), `shared_website`,
#' `brand` (a dominant shared name, such as a federation's chapters) and
#' `co_tenant` (a shared street address). `md_cluster()` lists an EIN's
#' clusters and their members, each with its best legal name, layer and state.
#'
#' @param ein An EIN whose clusters to show. Give this or `cluster_id`.
#' @param cluster_id One or more cluster ids.
#' @param types Cluster types to keep; `NULL` for all.
#' @param max_members The most members listed per cluster. A brand cluster can
#'   hold 25,000; `size` always reports the full count.
#' @param con A connection from [md_db()]; opened read-only and closed when
#'   `NULL`.
#' @return An `md_cluster`: a list with `clusters` (one row per cluster) and
#'   `members` (one row per listed member).
#' @examples
#' \dontrun{
#' md_cluster("53-0196605")
#' md_cluster("53-0196605", types = "related_system")$members
#' }
#' @export
md_cluster <- function(ein = NULL, cluster_id = NULL, types = NULL, max_members = 100L,
                       con = NULL) {
  if (is.null(ein) == is.null(cluster_id)) {
    stop("give either `ein` or `cluster_id`", call. = FALSE)
  }
  if (is.null(con)) { con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE) }
  if (!all(c("cluster", "cluster_member") %in% DBI::dbListTables(con))) {
    stop("this database has no cluster tables; run md_build_clusters()", call. = FALSE)
  }
  q <- function(sql, p = NULL) DBI::dbGetQuery(con, sql, params = p)
  if (!is.null(ein)) {
    e <- md_ein(ein)
    cluster_id <- q(sprintf("SELECT DISTINCT cluster_id FROM cluster_member WHERE ein IN (%s)",
                            paste(sprintf("'%s'", e), collapse = ", ")))$cluster_id
  }
  cc <- .md_cols(con, "cluster"); mc <- .md_cols(con, "cluster_member")
  duckdb::duckdb_register(con, "lk_cl", data.frame(cluster_id = unique(as.character(cluster_id)),
                                                   stringsAsFactors = FALSE))
  on.exit(duckdb::duckdb_unregister(con, "lk_cl"), add = TRUE, after = FALSE)
  type_ok <- if (is.null(types)) "TRUE" else
    sprintf("c.cluster_type IN (%s)", paste(sprintf("'%s'", types), collapse = ", "))
  size <- if ("size" %in% cc) "c.size" else
    "(SELECT count(*) FROM cluster_member x WHERE x.cluster_id = c.cluster_id)"
  opt_c <- intersect(c("label", "central_ein", "brand_tokens"), cc)
  clusters <- q(sprintf("
    SELECT c.cluster_id, c.cluster_type, %s AS size%s
    FROM cluster c JOIN lk_cl USING (cluster_id) WHERE %s
    ORDER BY size, c.cluster_type, c.cluster_id",
    size, .md_extra_cols(paste0("c.", opt_c)[length(opt_c) > 0]), type_ok))

  tabs <- DBI::dbListTables(con)
  # the name to show: the BMF legal name, else another legal, a dba, an alias
  nm <- if ("name" %in% tabs) "
    LEFT JOIN (SELECT n.ein, arg_min(n.name_raw, CASE
                 WHEN n.variant_class = 'legal' AND n.source = 'bmf' THEN 0
                 WHEN n.variant_class = 'legal' THEN 1 WHEN n.variant_class = 'dba' THEN 2
                 ELSE 3 END) AS name
               FROM name n
               WHERE n.variant_class <> 'in_care_of' AND n.ein IN
                 (SELECT ein FROM cluster_member JOIN lk_cl USING (cluster_id))
               GROUP BY n.ein) n ON n.ein = m.ein" else ""
  st <- if ("address" %in% tabs) "
    LEFT JOIN (SELECT ein, arg_min(state, CASE variant_class WHEN 'mailing' THEN 1
                 WHEN 'principal' THEN 2 ELSE 3 END) AS state FROM address
               WHERE coalesce(state, '') <> '' GROUP BY ein) s ON s.ein = m.ein" else ""
  ly <- if ("entity" %in% tabs) "LEFT JOIN entity e ON e.ein = m.ein" else ""
  sel <- c("m.cluster_id", "c.cluster_type", "m.ein",
           if ("role" %in% mc) "m.role", if ("evidence" %in% mc) "m.evidence",
           if (nzchar(nm)) "n.name", if (nzchar(ly)) "e.layer", if (nzchar(ly)) "e.active",
           if (nzchar(st)) "s.state")
  members <- q(sprintf("
    SELECT * EXCLUDE (rk) FROM (
      SELECT %s, row_number() OVER (PARTITION BY m.cluster_id ORDER BY %s m.ein) AS rk
      FROM cluster_member m JOIN lk_cl USING (cluster_id)
      JOIN cluster c ON c.cluster_id = m.cluster_id %s %s %s
      WHERE %s)
    WHERE rk <= %d ORDER BY cluster_id, rk",
    paste(sel, collapse = ", "),
    if ("role" %in% mc) "CASE WHEN m.role IN ('central', 'parent', 'anchor') THEN 0 ELSE 1 END," else "",
    nm, ly, st, type_ok, as.integer(max_members)))
  # keep the clusters' order
  members <- members[order(match(members$cluster_id, clusters$cluster_id)), , drop = FALSE]
  rownames(members) <- NULL
  structure(list(clusters = clusters, members = members), ein = if (!is.null(ein)) md_ein(ein),
            max_members = max_members, class = "md_cluster")
}

#' @export
print.md_cluster <- function(x, n = 8L, max_clusters = 10L, ...) {
  e <- attr(x, "ein")
  cat(sprintf("<md_cluster> %s%d cluster%s", if (length(e)) paste0(e[1], ": ") else "",
              nrow(x$clusters), if (nrow(x$clusters) == 1) "" else "s"))
  if (nrow(x$clusters)) {
    tb <- table(x$clusters$cluster_type)
    cat(" (", paste(names(tb), tb, sep = " ", collapse = ", "), ")", sep = "")
  }
  cat("\n")
  for (i in seq_len(min(nrow(x$clusters), max_clusters))) {
    cl <- x$clusters[i, ]
    m <- x$members[x$members$cluster_id == cl$cluster_id, , drop = FALSE]
    lab <- if (!is.null(cl$label) && !is.na(cl$label) &&
               !grepl(cl$label, cl$cluster_id, fixed = TRUE)) paste0("  ", cl$label) else ""
    cat(sprintf("\n  %s  %s, %s member%s%s\n", cl$cluster_id, cl$cluster_type,
                format(cl$size, big.mark = ","), if (cl$size == 1) "" else "s", lab))
    s <- utils::head(m, n)
    for (j in seq_len(nrow(s))) {
      cat(sprintf("    %s %s%-40s %s\n", if (length(e) && s$ein[j] %in% e) "*" else " ",
                  s$ein[j], if (!is.null(s$name)) paste0("  ", substr(s$name[j] %||% "", 1, 40)) else "",
                  if (!is.null(s$state)) s$state[j] %||% "" else ""))
    }
    if (cl$size > nrow(s)) cat(sprintf("      ... %s more\n", format(cl$size - nrow(s), big.mark = ",")))
  }
  if (nrow(x$clusters) > max_clusters) {
    cat(sprintf("\n  ... %d more clusters; see $clusters and $members\n",
                nrow(x$clusters) - max_clusters))
  }
  invisible(x)
}

.md_cols <- function(con, table) DBI::dbListFields(con, table)

# legal first, then dba, observed, in-care-of; addresses mailing first
.md_class_order_sql <- function(col) {
  sprintf("CASE %s WHEN 'legal' THEN 1 WHEN 'mailing' THEN 1 WHEN 'dba' THEN 2
          WHEN 'principal' THEN 2 WHEN 'observed' THEN 3 WHEN 'historical' THEN 3 ELSE 4 END", col)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# ", a, b" for optional select columns; "" when there are none
.md_extra_cols <- function(cols) if (length(cols)) paste0(", ", cols, collapse = "") else ""
