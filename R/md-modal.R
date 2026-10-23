#' Deterministically pick a representative value
#'
#' Generates SQL that chooses, per group, the most frequently occurring value of
#' a column, breaking ties by sorting the value itself. Used wherever an ingest
#' collapses many source rows into one and has to keep a single spelling.
#'
#' @section Why not mode():
#' DuckDB's `mode()` returns *an* most-common value, not *the* most-common one.
#' Under a tie it picks arbitrarily, and arbitrarily is not deterministically -
#' the choice can differ between runs over byte-identical input.
#'
#' That is not cosmetic. In the Schedule I ingest it changed the row count: a tie
#' between `''` and a real street name flipped which side of a non-empty filter
#' the row landed on, and two consecutive runs produced address counts differing
#' by one. Section 7c makes determinism a hard requirement - "the spec hash is
#' worthless if the same spec can yield different rows" - so a build that cannot
#' reproduce its own row count cannot be published against a hash at all.
#'
#' The same objection applies to every "give me a representative" aggregate:
#' `mode()`, `any_value()`, `first()`, `arg_max()` and `arg_min()` are all
#' arbitrary under ties. **None of them should appear in an ingest.** This
#' function exists so that the correct construction is shorter to write than the
#' incorrect one.
#'
#' @section What it generates:
#' A `row_number()` window partitioned by the grouping columns and ordered by
#' descending frequency then ascending value, filtered to rank 1. Frequency
#' decides; the value's own sort order settles ties. Both halves are total
#' orders over the input, so the result is a pure function of the data.
#'
#' Alphabetical is an arbitrary tiebreak in the sense that no spelling is more
#' correct than another - but it is a *fixed* arbitrary, which is the property
#' that matters. Prefer it over anything data-dependent like "longest" or "most
#' recent", which reintroduce ties of their own.
#'
#' @param table Source table or CTE name.
#' @param by Character vector of grouping columns.
#' @param value Column whose representative value is wanted.
#' @param where Optional SQL predicate applied before counting.
#' @param alias Name for the generated CTE.
#' @return A single SQL string defining the CTE.
#' @examples
#' cat(md_modal_sql("si_clean", c("ein", "name_key"), "name_raw"))
#' @export
md_modal_sql <- function(table, by, value, where = NULL, alias = NULL) {
  if (!length(by)) stop("`by` must name at least one column", call. = FALSE)
  alias <- alias %||% paste0("modal_", value)
  cols <- paste(by, collapse = ", ")
  sprintf(
    "%s AS (
      SELECT %s, %s,
             row_number() OVER (PARTITION BY %s
                                ORDER BY count(*) DESC, %s ASC) AS rk
      FROM %s%s
      GROUP BY %s, %s
    )",
    alias, cols, value, cols, value, table,
    if (is.null(where)) "" else paste0(" WHERE ", where),
    cols, value)
}

#' The frozen enumerations, as code
#'
#' Section 3a of the plan is normative; these functions are the single place the
#' vocabulary is written down for the package, so a validator and an ingest
#' cannot drift apart on what a legal value is.
#'
#' @return A character vector of permitted values.
#' @export
md_layers <- function() {
  # Append-only (PLAN.md section 3a). postcard_only and revoked_only were added
  # 2026-10-22 with the e-Postcard and revocation ingests: filer_only rows all
  # came from 990 e-file filings and schedules, so 990-N-only EINs get their own
  # value rather than widening an existing one.
  c("bmf_active", "bmf_inactive", "filer_only", "approved_only", "irs527",
    "postcard_only", "revoked_only")
}

#' @rdname md_layers
#' @export
md_name_classes <- function() {
  c("legal", "dba", "division", "in_care_of", "observed", "former")
}

#' @rdname md_layers
#' @export
md_address_classes <- function() {
  c("mailing", "principal", "observed", "historical")
}
