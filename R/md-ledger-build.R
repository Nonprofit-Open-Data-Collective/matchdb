#' Load the pinned source files into the ledger
#'
#' Walks the sources that write names or addresses, finds each one's pinned
#' files under `sources/<source>/<version>/`, parses each with its
#' `md_parse_*()` function and applies it with [md_apply_release()]: one
#' release per file, so a year-partitioned source is one partition per year.
#' Each file's md5 comes from the pin's `FILES.csv` when there is one, so a file
#' already applied is skipped on the next run.
#'
#' \tabular{lll}{
#'   source \tab version key \tab files \cr
#'   `bmf_unified` \tab `bmf_unified` \tab the pinned parquet \cr
#'   `efile_header`, `schedi`, `efile_related`, `efile_affiliate_listing` \tab
#'     `efile` \tab the published table, one `<TABLE>-YYYY.CSV` per tax year \cr
#'   `f1023ez` \tab `f1023ez` \tab `f1023ez-approvals-YYYY.csv`, the CSVs
#'     [md_ingest_f1023ez()] converts the workbooks to \cr
#'   `e_postcard` \tab `e_postcard` \tab `*-E-POSTCARD.csv` \cr
#'   `revocations` \tab `revocations` \tab `*-REVOCATIONS-ORGS.csv` \cr
#'   `address_crosswalk` \tab `address_crosswalk` \tab the pinned CSV \cr
#'   `bmf_active` \tab `bmf_active` \tab the pinned CSV, only if a version is given
#' }
#'
#' A source whose version is missing from `versions`, or whose files are not
#' there, is skipped with a message rather than failing the run.
#'
#' @param con A DuckDB connection.
#' @param versions A named list of versions, as in `dev/build-versions.R`.
#' @param sources Restrict to these sources. Default: every source above.
#' @return A data frame, one row per release, from [md_apply_release()].
#' @export
md_build_ledger <- function(con, versions, sources = NULL) {
  msg <- function(...) message(sprintf(...))
  ef <- c(efile_header = "F9-P00-T00-HEADER", schedi = "SI-P02-T01-GRANTS-US-ORGS-GOVTS",
          efile_related = "SR-P02-T01-ID-RLTD-TAX-EXEMPED-ORGS",
          efile_affiliate_listing = "F9-P00-T01-AFFILIATE-LISTING")
  parsers <- list(
    bmf_unified = md_parse_bmf_unified, bmf_active = md_parse_bmf_active,
    efile_header = md_parse_efile_header, schedi = md_parse_schedi,
    efile_related = md_parse_efile_related, efile_affiliate_listing = md_parse_affiliate_listing,
    f1023ez = md_parse_f1023ez, e_postcard = md_parse_e_postcard,
    revocations = md_parse_revocations, address_crosswalk = md_parse_address_crosswalk)
  todo <- if (is.null(sources)) names(parsers) else intersect(sources, names(parsers))
  out <- list()

  vkey <- function(s) if (s %in% names(ef)) "efile" else s
  for (s in todo) {
    v <- versions[[vkey(s)]]
    if (is.null(v)) { if (s != "bmf_active") msg("%s: no version given, skipped", s); next }
    dir <- md_path("sources", s, v)
    pat <- switch(s,
      bmf_unified = "[.]parquet$", bmf_active = "[.]csv$",
      f1023ez = "^f1023ez-approvals-[0-9]{4}[.]csv$",
      e_postcard = "E-POSTCARD[.]csv$", revocations = "REVOCATIONS-ORGS[.]csv$",
      address_crosswalk = "[.]csv$",
      sprintf("^%s-[0-9]{4}[.]CSV$", ef[[s]]))
    files <- sort(list.files(dir, pattern = pat, full.names = TRUE))
    # the pin's own checksum list sits beside the data and matches "[.]csv$"
    files <- files[basename(files) != "FILES.csv"]
    if (!length(files)) {
      msg("%s: no files matching %s in %s, skipped%s", s, pat, dir,
          if (s == "f1023ez") " (md_ingest_f1023ez() converts the workbooks)" else "")
      next
    }
    pinned <- md_source_read_files(s, v)
    for (f in files) {
      year <- regmatches(basename(f), regexpr("[0-9]{4}(?=[.][A-Za-z]+$)", basename(f), perl = TRUE))
      part <- if (s %in% c(names(ef), "f1023ez") && length(year)) year else NA
      vintage <- if (s %in% c("e_postcard", "revocations", "bmf_active")) sub("^v", "", v) else v
      md5 <- if (!is.null(pinned) && basename(f) %in% pinned$file) {
        pinned$md5[pinned$file == basename(f)]
      } else unname(tools::md5sum(f))
      path <- gsub("\\\\", "/", f)
      rel <- if (grepl("[.]parquet$", f)) sprintf("read_parquet('%s')", path) else
        sprintf("read_csv('%s', all_varchar = true, header = true, quote = '\"', escape = '\"')", path)
      frame <- if (s == "f1023ez") parsers[[s]](con, rel, year = as.integer(year))
               else parsers[[s]](con, rel)
      t0 <- Sys.time()
      r <- md_apply_release(con, frame, s, v, part = part, vintage = vintage, file_md5 = md5)
      msg("%-24s %-6s %-10s %8s rows  +%s  kept %s  retracted %s  (%.1fs)", s,
          if (is.na(part)) "" else part, r$status, format(r$n_rows, big.mark = ","),
          format(r$n_new, big.mark = ","), format(r$n_kept, big.mark = ","),
          format(r$n_retracted, big.mark = ","),
          as.numeric(difftime(Sys.time(), t0, units = "secs")))
      out[[length(out) + 1]] <- r
    }
  }
  invisible(if (length(out)) do.call(rbind, out) else NULL)
}
