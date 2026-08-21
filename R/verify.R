# ---------------------------------------------------------------------------
# The verification harness.
#
# Every matchdb phase gate reduces to "this reproduces the baseline". That is
# only falsifiable if two frames can be compared in a way that ignores
# differences carrying no information -- row order, column order, storage type,
# "" versus NA -- while catching every difference that does.
#
# Getting that boundary right is the whole job. Too strict and the gate fails on
# a factor level, an argument follows about whether the diff counts, and the
# criterion quietly weakens. Too loose and a real behaviour change slides
# through, which is the failure mode the plan exists to prevent.
#
# See matchdb/dev/PROCESS.md section 5.
# ---------------------------------------------------------------------------

#' Put a frame in comparison normal form
#'
#' Removes the differences that carry no information, so the ones that remain
#' are unambiguously behavioural:
#'
#' 1. restrict to `columns` — the **pinned** list from the 0a baseline manifest,
#'    never `npmatch::np_fields` resolved at run time (Phase 0c adds
#'    `variant_class` to it, so a live lookup would compare a baseline built
#'    without that column against a candidate built with it)
#' 2. coerce every comparison column to character, and `""` to `NA`
#' 3. order rows by `key`, dropping incidental row order
#' 4. order columns by name
#'
#' @param d A data frame.
#' @param columns Character vector of columns to compare. Required — passing the
#'   live field set is the mistake this argument exists to prevent.
#' @param key Columns identifying a row. Default the reference-frame key.
#' @return `d` in normal form, with a `.occ` column disambiguating rows that
#'   share a key (so duplicates are compared as a multiset rather than collapsed).
#' @export
md_normal_form <- function(d, columns,
                           key = c("ein", "name_key", "street_key", "zip5")) {
  d <- as.data.frame(d, stringsAsFactors = FALSE)
  if (missing(columns) || !length(columns))
    stop("`columns` is required: pin it from the baseline manifest.", call. = FALSE)
  missing_cols <- setdiff(columns, names(d))
  if (length(missing_cols))
    stop("frame is missing pinned column(s): ",
         paste(missing_cols, collapse = ", "), call. = FALSE)
  key <- intersect(key, columns)
  if (!length(key))
    stop("none of the key columns are in `columns`.", call. = FALSE)

  d <- d[, columns, drop = FALSE]
  for (n in names(d)) {
    v <- d[[n]]
    if (is.factor(v)) v <- as.character(v)
    if (is.logical(v) || is.numeric(v)) v <- as.character(v)
    v <- as.character(v)
    v[!is.na(v) & v == ""] <- NA_character_
    d[[n]] <- v
  }
  d <- d[, sort(names(d)), drop = FALSE]
  k <- do.call(paste, c(d[, key, drop = FALSE], sep = "\r"))
  ord <- order(k, method = "radix")
  d <- d[ord, , drop = FALSE]; k <- k[ord]
  # positional index within a repeated key, so N identical rows on one side and
  # N-1 on the other register as a difference instead of matching silently
  d$.occ <- stats::ave(seq_along(k), k, FUN = seq_along)
  attr(d, "md_key") <- c(key, ".occ")
  rownames(d) <- NULL
  d
}

#' Compare two frames against the gate criterion
#'
#' Reports the three counts a phase gate turns on: rows only in the baseline,
#' rows only in the candidate, and cells that differ on keys present in both.
#' **The gate passes when all three are zero.**
#'
#' @param baseline,candidate Data frames (raw; normal form is applied here).
#' @param columns Pinned comparison columns (see [md_normal_form()]).
#' @param key Row-identifying columns.
#' @param n_sample Rows/cells to retain per sample table. Default 10.
#' @return An `md_diff` object: the three counts, three sample tables, and a
#'   per-column tally of differing cells.
#' @export
md_compare_frames <- function(baseline, candidate, columns,
                              key = c("ein", "name_key", "street_key", "zip5"),
                              n_sample = 10L) {
  b <- md_normal_form(baseline, columns, key)
  c_ <- md_normal_form(candidate, columns, key)
  kk <- attr(b, "md_key")
  kb <- do.call(paste, c(b[, kk, drop = FALSE], sep = "\r"))
  kc <- do.call(paste, c(c_[, kk, drop = FALSE], sep = "\r"))

  only_b <- setdiff(kb, kc)
  only_c <- setdiff(kc, kb)
  both   <- intersect(kb, kc)

  ib <- match(both, kb); ic <- match(both, kc)
  cmp <- setdiff(names(b), c(kk, ".occ"))
  per_col <- integer(0); cells <- 0L; ex <- NULL
  for (n in cmp) {
    x <- b[[n]][ib]; y <- c_[[n]][ic]
    d <- !((is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & x == y))
    nd <- sum(d)
    if (nd > 0L) {
      per_col[[n]] <- nd; cells <- cells + nd
      if (is.null(ex) || nrow(ex) < n_sample) {
        w <- utils::head(which(d), n_sample)
        ex <- rbind(ex, data.frame(key = both[w], column = n,
                                   baseline = x[w], candidate = y[w],
                                   stringsAsFactors = FALSE))
      }
    }
  }
  structure(list(
    n_only_baseline  = length(only_b),
    n_only_candidate = length(only_c),
    n_cells_differ   = cells,
    n_compared       = length(both),
    per_column       = sort(per_col, decreasing = TRUE),
    sample_only_baseline  = utils::head(b[match(only_b, kb), , drop = FALSE], n_sample),
    sample_only_candidate = utils::head(c_[match(only_c, kc), , drop = FALSE], n_sample),
    sample_cells     = utils::head(ex, n_sample),
    passed = length(only_b) == 0L && length(only_c) == 0L && cells == 0L
  ), class = "md_diff")
}

#' Compare two tiered benchmark outputs
#'
#' Stricter than [md_compare_frames()] and shaped differently, because tiered
#' results do **not** share an identity set across references: the frame carries
#' one row per identity that drew at least one candidate, and a larger reference
#' reaches more of them (4,733 identities on the monthly BMF against 4,793 on the
#' augmented one — `pfmatch/dev/VARIANT-CLASS-AB.md`).
#'
#' So align on the union of `.id` and mark an absent identity `NONE`, which is
#' distinct from a scored `NO`: no candidate was ever generated, rather than one
#' generated and rejected. Comparing without this reports phantom differences.
#'
#' @param baseline,candidate Tiered result frames (`np_tiered` or plain).
#' @param columns Columns compared. Default the verdict-bearing four.
#' @param n_sample Rows to retain in the sample table. Default 10.
#' @return An `md_diff` object.
#' @export
md_compare_tiered <- function(baseline, candidate,
                              columns = c(".id", "overall_ein", "tier",
                                          "decision_score"),
                              n_sample = 10L) {
  b <- as.data.frame(baseline, stringsAsFactors = FALSE)
  c_ <- as.data.frame(candidate, stringsAsFactors = FALSE)
  for (nm in c("b", "c_")) {
    d <- get(nm)
    miss <- setdiff(columns, names(d))
    if (length(miss))
      stop(nm, " is missing column(s): ", paste(miss, collapse = ", "), call. = FALSE)
  }
  ids <- sort(unique(c(b$.id, c_$.id)))
  align <- function(d) {
    i <- match(ids, d$.id)
    out <- d[i, columns, drop = FALSE]
    out$.id <- ids
    out$tier <- as.character(out$tier)
    out$tier[is.na(i)] <- "NONE"
    for (n in setdiff(columns, ".id")) out[[n]] <- as.character(out[[n]])
    rownames(out) <- NULL
    out
  }
  b <- align(b); c_ <- align(c_)

  cmp <- setdiff(columns, ".id")
  per_col <- integer(0); cells <- 0L; ex <- NULL
  for (n in cmp) {
    x <- b[[n]]; y <- c_[[n]]
    d <- !((is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & x == y))
    if (sum(d)) {
      per_col[[n]] <- sum(d); cells <- cells + sum(d)
      w <- utils::head(which(d), n_sample)
      ex <- rbind(ex, data.frame(.id = ids[w], column = n, baseline = x[w],
                                 candidate = y[w], stringsAsFactors = FALSE))
    }
  }
  empty <- b[0, , drop = FALSE]
  structure(list(
    n_only_baseline  = sum(b$tier == "NONE" & c_$tier != "NONE"),
    n_only_candidate = sum(c_$tier == "NONE" & b$tier != "NONE"),
    n_cells_differ   = cells,
    n_compared       = length(ids),
    per_column       = sort(per_col, decreasing = TRUE),
    sample_only_baseline  = empty, sample_only_candidate = empty,
    sample_cells     = utils::head(ex, n_sample),
    passed = cells == 0L
  ), class = "md_diff")
}

#' @export
print.md_diff <- function(x, ...) {
  cat("<md_diff>", if (x$passed) "PASS" else "**FAIL**", "\n")
  cat(sprintf("  rows only in baseline   %8d\n", x$n_only_baseline))
  cat(sprintf("  rows only in candidate  %8d\n", x$n_only_candidate))
  cat(sprintf("  cells differing         %8d   (over %s compared rows)\n",
              x$n_cells_differ, format(x$n_compared, big.mark = ",")))
  if (length(x$per_column)) {
    cat("  by column:\n")
    for (n in names(x$per_column))
      cat(sprintf("    %-24s %8d\n", n, x$per_column[[n]]))
  }
  if (!is.null(x$sample_cells) && nrow(x$sample_cells)) {
    cat("  sample differing cells:\n")
    print(utils::head(x$sample_cells, 10), row.names = FALSE)
  }
  invisible(x)
}
