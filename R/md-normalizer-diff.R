#' What a new normalizer would change
#'
#' Phase 5 step 7 (`dev/IDENTITY.md` §7). Derived columns are stored per
#' string and per normalizer signature ([md_build_text_derived()]), so after
#' installing a new npmatch the old signature's rows are still there beside the
#' new one's. This compares the two before the new one is adopted:
#'
#' \describe{
#'   \item{`coverage`}{Strings with a row under each signature, and under both.}
#'   \item{`columns`}{For every derived column, how many strings got a
#'     different value.}
#'   \item{`examples`}{Up to `examples` changed strings per column, with the old
#'     and new value.}
#'   \item{`groups`}{What that does to the rows of `name` and `address`: per
#'     EIN, groups that merge (rows with different old keys now share one) and
#'     groups that split (rows sharing an old key now differ), on `name_key`
#'     for names and on `street_key` plus ZIP for addresses, and how many EINs
#'     either touches. These are the rows whose compact group, and so whose
#'     compiled reference row, would change.}
#' }
#'
#' Workflow: with the old npmatch installed, [md_build_text_derived()] has
#' stored the old signature. Install the new npmatch and run
#' [md_build_text_derived()] again, which adds the new signature beside it. Then
#' run this. Adopt the new signature by rebuilding with it; drop the old rows
#' only when no published tier still names it.
#'
#' @param con A DuckDB connection.
#' @param old,new The two normalizer signatures. `new` defaults to the
#'   installed npmatch's.
#' @param examples Changed strings to show per column.
#' @return An object of class `md_normalizer_diff`: a list of the four data
#'   frames above, plus `old` and `new`.
#' @export
md_normalizer_diff <- function(con, old, new = npnormalize::np_normalize_signature(),
                               examples = 5L) {
  if (identical(old, new)) stop("old and new are the same signature", call. = FALSE)
  md_identity_macros(con)
  q <- function(x) DBI::dbQuoteString(con, x)
  specs <- list(
    list(tbl = "name", dtable = "name_text_derived", text = "name_text", id = "name_text_id",
         label = "name_raw", cols = .md_derived_name_cols, key = "name_key", by_zip = FALSE),
    list(tbl = "address", dtable = "address_text_derived", text = "address_text",
         id = "address_text_id", label = "street_raw", cols = .md_address_cols(),
         key = "street_key", by_zip = TRUE))
  coverage <- columns <- ex <- groups <- list()

  for (s in specs) {
    if (!DBI::dbExistsTable(con, s$dtable)) next
    have <- DBI::dbListFields(con, s$dtable)
    cols <- intersect(s$cols, have)
    sigs <- DBI::dbGetQuery(con, sprintf("
      SELECT count(*) FILTER (WHERE normalize_signature = %s) AS n_old,
             count(*) FILTER (WHERE normalize_signature = %s) AS n_new
      FROM %s", q(old), q(new), s$dtable))
    both <- sprintf("
      FROM %s o JOIN %s w ON w.%s = o.%s
      WHERE o.normalize_signature = %s AND w.normalize_signature = %s",
      s$dtable, s$dtable, s$id, s$id, q(old), q(new))
    n_both <- DBI::dbGetQuery(con, paste("SELECT count(*) AS n", both))$n
    coverage[[s$tbl]] <- data.frame(table = s$dtable, n_old = sigs$n_old, n_new = sigs$n_new,
                                    n_both = n_both)
    if (!length(cols)) next

    changed <- DBI::dbGetQuery(con, sprintf("SELECT %s %s", paste(sprintf(
      "count(*) FILTER (WHERE o.\"%s\" IS DISTINCT FROM w.\"%s\") AS \"%s\"", cols, cols, cols),
      collapse = ", "), both))
    columns[[s$tbl]] <- data.frame(table = s$dtable, column = cols, n_compared = n_both,
      n_changed = as.numeric(unlist(changed[1, cols])),
      pct_changed = round(100 * as.numeric(unlist(changed[1, cols])) / max(n_both, 1), 3),
      stringsAsFactors = FALSE)

    for (cl in cols[columns[[s$tbl]]$n_changed > 0]) {
      ex[[paste(s$tbl, cl)]] <- DBI::dbGetQuery(con, sprintf("
        SELECT '%s' AS \"table\", '%s' AS \"column\", t.%s AS text,
               CAST(o.\"%s\" AS VARCHAR) AS old, CAST(w.\"%s\" AS VARCHAR) AS new
        %s AND o.\"%s\" IS DISTINCT FROM w.\"%s\"
        ORDER BY t.%s LIMIT %d",
        s$dtable, cl, s$label, cl, cl,
        sub(sprintf("FROM %s o", s$dtable),
            sprintf("FROM %s o JOIN %s t ON t.%s = o.%s", s$dtable, s$text, s$id, s$id),
            both, fixed = TRUE),
        cl, cl, s$label, as.integer(examples)))
    }

    if (DBI::dbExistsTable(con, s$tbl) && s$key %in% cols) {
      groups[[s$tbl]] <- .md_diff_groups(con, s, q(old), q(new))
    }
  }
  structure(list(old = old, new = new,
                 coverage = do.call(rbind, coverage), columns = do.call(rbind, columns),
                 examples = if (length(ex)) do.call(rbind, ex) else NULL,
                 groups = do.call(rbind, groups)),
            class = "md_normalizer_diff")
}

# Merges and splits of each row's key group within its EIN.
.md_diff_groups <- function(con, s, old, new) {
  fields <- DBI::dbListFields(con, s$tbl)
  tid <- if (s$id %in% fields) sprintf("r.%s", s$id) else if (s$tbl == "name") {
    "md_name_text_id(r.name_raw)"
  } else "md_address_text_id(r.street_raw, NULL, r.city_raw, r.state, r.zip5, r.zip_plus4)"
  zip <- if (s$by_zip) " || '|' || coalesce(r.zip5, '')" else ""
  DBI::dbGetQuery(con, sprintf("
    WITH r AS (
      SELECT r.ein, coalesce(o.%s, '')%s AS k_old, coalesce(w.%s, '')%s AS k_new
      FROM %s r
      JOIN %s o ON o.%s = %s AND o.normalize_signature = %s
      JOIN %s w ON w.%s = %s AND w.normalize_signature = %s
    ), merged AS (SELECT ein, k_new FROM r GROUP BY 1, 2 HAVING count(DISTINCT k_old) > 1),
       split  AS (SELECT ein, k_old FROM r GROUP BY 1, 2 HAVING count(DISTINCT k_new) > 1)
    SELECT '%s' AS \"table\", '%s' AS key,
           (SELECT count(*) FROM r) AS n_rows,
           (SELECT count(*) FROM r WHERE k_old <> k_new) AS n_rows_rekeyed,
           (SELECT count(*) FROM merged) AS n_merged_groups,
           (SELECT count(*) FROM split) AS n_split_groups,
           (SELECT count(DISTINCT ein) FROM (SELECT ein FROM merged UNION SELECT ein FROM split))
             AS n_eins_regrouped",
    s$key, zip, s$key, zip, s$tbl, s$dtable, s$id, tid, old, s$dtable, s$id, tid, new,
    s$tbl, if (s$by_zip) "street_key + zip5" else s$key))
}

#' @export
print.md_normalizer_diff <- function(x, ...) {
  cat(sprintf("normalizer diff: %s -> %s\n\n", x$old, x$new))
  cat("strings with a row under each signature:\n")
  print(x$coverage, row.names = FALSE)
  if (!is.null(x$columns)) {
    ch <- x$columns[x$columns$n_changed > 0, , drop = FALSE]
    cat(sprintf("\nderived columns changed: %d of %d\n", nrow(ch), nrow(x$columns)))
    if (nrow(ch)) print(ch, row.names = FALSE)
  }
  if (!is.null(x$groups)) {
    cat("\neffect on name and address rows:\n")
    print(x$groups, row.names = FALSE)
  }
  if (!is.null(x$examples)) {
    cat("\nexamples:\n")
    print(x$examples, row.names = FALSE)
  }
  invisible(x)
}
