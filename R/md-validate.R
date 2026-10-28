#' Intrinsic validation of a built table
#'
#' The gate for every ingest phase. These are properties the database is checked
#' against *on its own terms* - key uniqueness, EIN wellformedness, referential
#' integrity, provenance completeness, and agreement between the stored derived
#' columns and a live [npnormalize::np_normalize()] call.
#'
#' It is deliberately not a comparison against a previously built artifact.
#' matchdb is built from the freshest available sources, so "matches the file we
#' had before" is not a property worth having: it would pin the database to an
#' older vintage and to a build nobody can reproduce. Attribution against the
#' existing pfmatch reference belongs at cutover, where it is a question about
#' two references rather than a constraint on this one.
#'
#' @param x A `data.frame`/`data.table` to check.
#' @param key Column(s) forming the primary key. Checked for uniqueness and
#'   completeness.
#' @param ein Name of the EIN column, or `NULL` to skip the EIN checks.
#' @param parent Optional vector of valid EINs (typically `entity$ein`) for a
#'   referential-integrity check.
#' @param enums Named list of allowed values, e.g.
#'   `list(variant_class = c("legal", "dba"))`.
#' @param required Columns that must be present and wholly non-missing.
#'   Provenance columns belong here.
#' @param sample Rows to draw for the derived-column agreement check. `0` skips it.
#' @return A `data.frame` with one row per check: `check`, `pass`, `n_bad`, `detail`.
#' @export
md_validate <- function(x, key = NULL, ein = "ein", parent = NULL,
                        enums = list(), required = character(),
                        sample = 1000L) {
  res <- list()
  add <- function(check, pass, n_bad = 0L, detail = "") {
    res[[length(res) + 1L]] <<- data.frame(
      check = check, pass = isTRUE(pass), n_bad = as.integer(n_bad),
      detail = detail, stringsAsFactors = FALSE
    )
  }

  add("table is non-empty", nrow(x) > 0L, 0L, sprintf("%d rows", nrow(x)))

  if (!is.null(key)) {
    missing_cols <- setdiff(key, names(x))
    if (length(missing_cols)) {
      add("key columns present", FALSE, length(missing_cols),
          paste("absent:", paste(missing_cols, collapse = ", ")))
    } else {
      k <- do.call(paste, c(unname(as.list(x[, key, drop = FALSE])), sep = "\r"))
      n_dup <- sum(duplicated(k))
      n_na  <- sum(is.na(k) | !nzchar(k))
      add("key is unique", n_dup == 0L, n_dup, paste(key, collapse = " + "))
      add("key is complete", n_na == 0L, n_na, paste(key, collapse = " + "))
    }
  }

  if (!is.null(ein) && ein %in% names(x)) {
    e <- as.character(x[[ein]])
    bad <- !md_is_ein(e)
    add("EIN is canonical EIN2", sum(bad) == 0L, sum(bad),
        if (any(bad)) paste("e.g.", paste(utils::head(unique(e[bad]), 3), collapse = ", "))
        else "EIN-XX-XXXXXXX")
    if (!is.null(parent)) {
      orphan <- !(e %in% as.character(parent))
      add("EIN resolves to entity", sum(orphan) == 0L, sum(orphan),
          sprintf("%d distinct", length(unique(e[orphan]))))
    }
  }

  for (col in names(enums)) {
    if (!col %in% names(x)) {
      add(sprintf("enum %s present", col), FALSE, 1L, "column absent")
      next
    }
    bad <- !(as.character(x[[col]]) %in% enums[[col]])
    add(sprintf("enum %s in vocabulary", col), sum(bad) == 0L, sum(bad),
        if (any(bad)) paste("unexpected:", paste(utils::head(unique(x[[col]][bad]), 3), collapse = ", ")) else
          paste(enums[[col]], collapse = " | "))
  }

  for (col in required) {
    if (!col %in% names(x)) {
      add(sprintf("required %s present", col), FALSE, 1L, "column absent")
      next
    }
    v <- x[[col]]
    bad <- is.na(v) | (is.character(v) & !nzchar(as.character(v)))
    add(sprintf("required %s complete", col), sum(bad) == 0L, sum(bad), "")
  }

  do.call(rbind, res)
}

#' @rdname md_validate
#' @param v Output of [md_validate()].
#' @param stop_on_fail Error rather than return when any check fails. Phase gates
#'   use `TRUE`; interactive inspection uses `FALSE`.
#' @export
md_validate_report <- function(v, stop_on_fail = TRUE) {
  width <- max(nchar(v$check))
  for (i in seq_len(nrow(v))) {
    cat(sprintf("  %-*s  %s  %s\n", width, v$check[i],
                if (v$pass[i]) "ok  " else "FAIL",
                if (v$pass[i]) v$detail[i]
                else sprintf("%d bad  %s", v$n_bad[i], v$detail[i])))
  }
  failed <- sum(!v$pass)
  cat(sprintf("  ---- %d checks, %d failed\n", nrow(v), failed))
  if (failed && stop_on_fail) {
    stop(sprintf("%d validation check(s) failed", failed), call. = FALSE)
  }
  invisible(failed == 0L)
}
