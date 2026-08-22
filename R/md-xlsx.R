#' Convert a large .xlsx to CSV by streaming its XML
#'
#' The IRS publishes the Form 1023-EZ approvals as `.xlsx` only. The 2023 file
#' is 47 MB compressed but **313 MB of sheet XML**, and every in-process reader
#' available here dies on it: `readxl::read_excel()` and DuckDB's `read_xlsx()`
#' both segfault rather than erroring, which is worth knowing because a segfault
#' in a build script looks like a crash, not like unsupported input.
#'
#' So this reads the archive directly. An `.xlsx` is a zip; the sheet is XML with
#' one `<row>` per record and cells that reference a shared string table by
#' index. Both parts are split on their closing tags into lines and processed a
#' chunk at a time, so peak memory is a function of chunk size rather than file
#' size.
#'
#' @param xlsx Path to the workbook.
#' @param out Path to write. Defaults to the input with a `.csv` extension.
#' @param sheet Sheet number within the workbook.
#' @param chunk Rows held in memory at once.
#' @return `out`, invisibly.
#' @export
md_xlsx_to_csv <- function(xlsx, out = NULL, sheet = 1L, chunk = 50000L) {
  if (!file.exists(xlsx)) stop("no such file: ", xlsx, call. = FALSE)
  if (is.null(out)) out <- sub("[.][xX][lL][sS][xX]$", ".csv", xlsx)
  tmp <- tempfile("mdxlsx"); dir.create(tmp); on.exit(unlink(tmp, recursive = TRUE))

  ss_raw <- file.path(tmp, "ss.xml")
  sh_raw <- file.path(tmp, "sheet.xml")
  .md_unzip_member(xlsx, "xl/sharedStrings.xml", ss_raw)
  .md_unzip_member(xlsx, sprintf("xl/worksheets/sheet%d.xml", sheet), sh_raw)

  strings <- .md_shared_strings(ss_raw)
  message(sprintf("  shared strings: %s", format(length(strings), big.mark = ",")))

  rows_file <- file.path(tmp, "rows.txt")
  .md_split_on(sh_raw, "</row>", rows_file)

  con_in  <- file(rows_file, "r")
  con_out <- file(out, "w")
  on.exit({ close(con_in); close(con_out) }, add = TRUE)

  header <- NULL
  n <- 0L
  repeat {
    lines <- readLines(con_in, n = chunk, warn = FALSE)
    if (!length(lines)) break
    lines <- lines[grepl("<row", lines, fixed = TRUE)]
    if (!length(lines)) next
    recs <- lapply(lines, .md_parse_row, strings = strings)
    width <- max(vapply(recs, length, integer(1)))
    if (is.null(header)) {
      header <- recs[[1]]
      width <- length(header)
      recs <- recs[-1]
      utils::write.table(matrix(header, nrow = 1), con_out, sep = ",",
                         row.names = FALSE, col.names = FALSE, qmethod = "double")
    }
    if (!length(recs)) next
    m <- t(vapply(recs, function(r) {
      length(r) <- length(header); r
    }, character(length(header))))
    utils::write.table(m, con_out, sep = ",", row.names = FALSE,
                       col.names = FALSE, na = "", qmethod = "double")
    n <- n + nrow(m)
  }
  message(sprintf("  wrote %s rows to %s", format(n, big.mark = ","), basename(out)))
  invisible(out)
}

.md_unzip_member <- function(zip, member, dest) {
  ok <- suppressWarnings(system2("unzip", c("-p", shQuote(zip), shQuote(member)),
                                 stdout = dest, stderr = FALSE))
  if (!file.exists(dest) || file.size(dest) == 0) {
    stop("could not extract ", member, " from ", basename(zip), call. = FALSE)
  }
  dest
}

# Insert a newline after every occurrence of `tag` so a single-line XML document
# becomes line-oriented and can be read incrementally.
.md_split_on <- function(src, tag, dest) {
  system2("sed", c("-e", shQuote(paste0("s|", tag, "|", tag, "\\n|g")), shQuote(src)),
          stdout = dest, stderr = FALSE)
  dest
}

# The shared string table. An <si> may hold several <t> runs (rich text); they
# concatenate into one value, which is why this cannot simply grep for <t>.
.md_shared_strings <- function(path) {
  split_file <- paste0(path, ".lines")
  .md_split_on(path, "</si>", split_file)
  con <- file(split_file, "r"); on.exit(close(con))
  out <- character(0)
  repeat {
    lines <- readLines(con, n = 100000L, warn = FALSE)
    if (!length(lines)) break
    lines <- lines[grepl("<si>", lines, fixed = TRUE)]
    if (!length(lines)) next
    vals <- vapply(regmatches(lines, gregexpr("<t[^>]*>[^<]*</t>", lines)),
                   function(ts) {
                     if (!length(ts)) return("")
                     paste0(sub("^<t[^>]*>", "", sub("</t>$", "", ts)), collapse = "")
                   }, character(1))
    out <- c(out, vals)
  }
  .md_unescape(out)
}

# One <row>. Cells are placed by their column reference rather than by order,
# because xlsx omits empty cells entirely - reading positionally would shift
# every value after the first gap into the wrong column.
.md_parse_row <- function(line, strings) {
  cells <- regmatches(line, gregexpr("<c [^>]*/>|<c [^>]*>.*?</c>", line))[[1]]
  if (!length(cells)) return(character(0))
  refs <- sub("^<c [^>]*r=\"([A-Z]+)[0-9]+\".*$", "\\1", cells)
  idx  <- .md_col_index(refs)
  is_s <- grepl("t=\"s\"", cells, fixed = TRUE)
  vals <- rep(NA_character_, length(cells))
  has_v <- grepl("<v>", cells, fixed = TRUE)
  raw <- sub("^.*<v>(.*?)</v>.*$", "\\1", cells[has_v])
  vals[has_v] <- raw
  si <- is_s & has_v
  if (any(si)) {
    j <- suppressWarnings(as.integer(vals[si])) + 1L
    vals[si] <- strings[j]
  }
  # inline strings <is><t>..</t></is>
  inl <- grepl("t=\"inlineStr\"", cells, fixed = TRUE)
  if (any(inl)) {
    vals[inl] <- .md_unescape(sub("^.*<t[^>]*>(.*?)</t>.*$", "\\1", cells[inl]))
  }
  out <- rep(NA_character_, max(idx))
  out[idx] <- vals
  out
}

# "A" -> 1, "Z" -> 26, "AA" -> 27, "BQ" -> 69
.md_col_index <- function(refs) {
  vapply(refs, function(r) {
    ch <- utf8ToInt(r) - 64L
    Reduce(function(a, b) a * 26L + b, ch, 0L)
  }, integer(1), USE.NAMES = FALSE)
}

.md_unescape <- function(x) {
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&apos;", "'", x, fixed = TRUE)
  gsub("&amp;", "&", x, fixed = TRUE)
}
