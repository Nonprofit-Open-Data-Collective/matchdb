#' Build the derived-column tables
#'
#' Runs [npmatch::np_normalize()] over `name` and `address` and stores the output
#' as `name_derived` and `address_derived`, keyed on `name_id` / `address_id`.
#'
#' @section Why separate tables rather than columns:
#' §9 says the normalizer will drift, and it already has once. When it does, the
#' derived values are stale and the base rows are not. Separate tables make that
#' a `DROP` and a rebuild rather than an `ALTER` rewriting 18.5M rows in tables
#' that are meant to be append-only, and they let the signature be checked per
#' table: a mismatch says exactly which artifact to rebuild.
#'
#' @section Why it costs what it costs:
#' `np_normalize()` computes all 19 derived columns regardless of input, so the
#' name pass also parses streets over stub columns and the address pass parses
#' names it will not keep. Measured at 18.1 s and 14.0 s per 200,000 rows, which
#' is roughly 36 minutes for both tables and about half of that wasted. The
#' waste is accepted deliberately: calling the exported function is what makes
#' `np_normalize_signature()` a true statement about how these columns were
#' produced. Calling internals would be faster and would make the stamp a lie.
#'
#' @param con A connection from [md_db()].
#' @param what Which tables to build.
#' @param chunk Rows per pass. Bounds peak memory, not correctness.
#' @return Row counts, invisibly.
#' @export
md_build_derived <- function(con = NULL, what = c("name", "address"),
                             chunk = 1000000L) {
  if (!requireNamespace("npmatch", quietly = TRUE)) {
    stop("npmatch is required", call. = FALSE)
  }
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  sig <- npmatch::np_normalize_signature()
  msg <- function(...) message(sprintf(...))
  msg("normalizer signature: %s", sig)

  blank <- function(n) rep("", n)
  out <- integer(0)

  if ("name" %in% what) {
    keep <- c("name_key", "name_full", "name_form", "name_gen", "name_gen_rank",
              "name_nums", "name_ord", "name_dir")
    out["name"] <- .md_derive_pass(
      con, src = "name", id = "name_id", dest = "name_derived", keep = keep,
      chunk = chunk, sig = sig, msg = msg,
      shape = function(d) data.frame(
        name = ifelse(is.na(d$name_raw), "", d$name_raw),
        dba = blank(nrow(d)), division = blank(nrow(d)), street = blank(nrow(d)),
        zip5 = blank(nrow(d)), zip_plus4 = blank(nrow(d)), state = blank(nrow(d)),
        stringsAsFactors = FALSE),
      select = "SELECT name_id AS id, name_raw FROM name")
  }

  if ("address" %in% what) {
    keep <- c("street_key", "street_num", "street_name", "street_type",
              "street_unit", "is_po_box", "zip3", "zip9", "state_abb")
    out["address"] <- .md_derive_pass(
      con, src = "address", id = "address_id", dest = "address_derived",
      keep = keep, chunk = chunk, sig = sig, msg = msg,
      shape = function(d) data.frame(
        name = blank(nrow(d)), dba = blank(nrow(d)), division = blank(nrow(d)),
        street = ifelse(is.na(d$street_raw), "", d$street_raw),
        zip5 = ifelse(is.na(d$zip5), "", d$zip5),
        zip_plus4 = ifelse(is.na(d$zip_plus4), "", d$zip_plus4),
        state = ifelse(is.na(d$state), "", d$state),
        stringsAsFactors = FALSE),
      select = "SELECT address_id AS id, street_raw, zip5, zip_plus4, state FROM address")
  }
  invisible(out)
}

.md_derive_pass <- function(con, src, id, dest, keep, chunk, sig, msg,
                            shape, select) {
  n <- DBI::dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s", src))$n
  msg("%s: %s rows, %d chunks of %s", src, format(n, big.mark = ","),
      ceiling(n / chunk), format(chunk, big.mark = ","))
  DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s", dest))

  t0 <- Sys.time(); done <- 0L; first <- TRUE
  for (off in seq(0, n - 1, by = chunk)) {
    d <- DBI::dbGetQuery(con, sprintf("%s ORDER BY %s LIMIT %d OFFSET %d",
                                      select, id, chunk, off))
    if (!nrow(d)) break
    o <- npmatch::np_normalize(shape(d))
    res <- cbind(stats::setNames(d["id"], id), o[, keep, drop = FALSE])
    res$normalize_signature <- sig
    if (first) { DBI::dbWriteTable(con, dest, res); first <- FALSE
    } else      { DBI::dbAppendTable(con, dest, res) }
    done <- done + nrow(d)
    el <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
    msg("  %s / %s  (%.1f min elapsed, ~%.1f min left)",
        format(done, big.mark = ","), format(n, big.mark = ","),
        el, el / max(done, 1) * (n - done))
  }
  msg("%s -> %s: %s rows in %.1f min", src, dest, format(done, big.mark = ","),
      as.numeric(difftime(Sys.time(), t0, units = "mins")))
  done
}
