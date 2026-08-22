#' Extract named columns from a large .xlsx by streaming its XML
#'
#' The IRS publishes the Form 1023-EZ approvals as `.xlsx` only. The 2023 file
#' is 47 MB compressed but **313 MB of sheet XML** over 7.2 million string cells,
#' and every in-process reader available here dies on it: `readxl::read_excel()`
#' and DuckDB's `read_xlsx()` both **segfault** rather than erroring. Worth
#' recording, because a segfault inside a build script reads as a crash rather
#' than as unsupported input.
#'
#' So this reads the archive directly. An `.xlsx` is a zip; the sheet is XML with
#' one `<row>` per record, and cells reference a shared string table by index.
#'
#' @section Why it takes column names:
#' Extracting all 70-odd columns row by row is slow enough to be unusable - the
#' work is proportional to cells, and most of those cells are not wanted. Naming
#' the columns turns the job into one vectorised regex per column per chunk.
#'
#' It is also a disclosure control rather than only an optimisation. Columns
#' 18-57 of the 1023-EZ approvals are five officers' **personal names and home
#' addresses**. matchdb is a database of organisations; there is no reason for
#' that data to enter it, and the cheapest way to guarantee it does not is to
#' never parse those columns.
#'
#' @param xlsx Path to the workbook.
#' @param columns Header names to keep. `NULL` keeps everything, which is only
#'   advisable on small sheets.
#' @param out Path to write. Defaults to the input with a `.csv` extension.
#' @param sheet Sheet number within the workbook.
#' @param chunk Rows held in memory at once.
#' @return `out`, invisibly.
#' @export
md_xlsx_to_csv <- function(xlsx, columns = NULL, out = NULL, sheet = 1L,
                           chunk = 20000L) {
  if (!file.exists(xlsx)) stop("no such file: ", xlsx, call. = FALSE)
  if (is.null(out)) out <- sub("[.][xX][lL][sS][xX]$", ".csv", xlsx)
  tmp <- tempfile("mdxlsx"); dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

  ss <- .md_unzip_member(xlsx, "xl/sharedStrings.xml", file.path(tmp, "ss.xml"))
  sh <- .md_unzip_member(xlsx, sprintf("xl/worksheets/sheet%d.xml", sheet),
                         file.path(tmp, "sheet.xml"))

  strings <- .md_shared_strings(ss)
  message(sprintf("  %s shared strings", format(length(strings), big.mark = ",")))

  rows_file <- .md_split_on(sh, "</row>", file.path(tmp, "rows.txt"))
  con_in <- file(rows_file, "r"); on.exit(close(con_in), add = TRUE)

  # Header row first: it maps the names asked for onto column letters.
  first <- .md_next_rows(con_in, 1L)
  if (!length(first)) stop("no rows in sheet ", sheet, call. = FALSE)
  hdr <- .md_row_cells(first[1], strings)
  names(hdr$value) <- hdr$ref
  header <- hdr$value

  if (is.null(columns)) columns <- unname(header)
  # Case-insensitive, because publishers rename columns between releases without
  # saying so: the 1023-EZ approvals header is `EIN` in 2014 and `Ein` in 2023.
  # Requested spellings are what get written, so downstream code sees one schema.
  hit <- match(tolower(columns), tolower(header))
  missing <- columns[is.na(hit)]
  if (length(missing)) {
    stop("column(s) not in the sheet: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }
  letters_wanted <- names(header)[hit]
  message(sprintf("  keeping %d of %d columns", length(columns), length(header)))

  con_out <- file(out, "w"); on.exit(close(con_out), add = TRUE)
  utils::write.table(matrix(columns, nrow = 1), con_out, sep = ",",
                     row.names = FALSE, col.names = FALSE, qmethod = "double")

  n <- 0L
  repeat {
    lines <- .md_next_rows(con_in, chunk)
    if (!length(lines)) break
    m <- vapply(letters_wanted, function(L) .md_col_values(lines, L, strings),
                character(length(lines)))
    if (length(lines) == 1L) m <- matrix(m, nrow = 1L)
    utils::write.table(m, con_out, sep = ",", row.names = FALSE,
                       col.names = FALSE, na = "", qmethod = "double")
    n <- n + nrow(m)
  }
  message(sprintf("  wrote %s rows to %s", format(n, big.mark = ","), basename(out)))
  invisible(out)
}

.md_next_rows <- function(con, n) {
  out <- character(0)
  while (length(out) < n) {
    got <- readLines(con, n = n - length(out), warn = FALSE)
    if (!length(got)) break
    got <- got[grepl("<row", got, fixed = TRUE)]
    out <- c(out, got)
  }
  out
}

# All values in one column letter, across many row-lines, vectorised. Absent
# cells give NA, which is the correct reading: xlsx omits empty cells entirely.
.md_col_values <- function(lines, letter, strings) {
  pat <- sprintf('<c r="%s[0-9]+"[^>]*(/>|>.*?</c>)', letter)
  m <- regexpr(pat, lines)
  out <- rep(NA_character_, length(lines))
  hit <- m != -1L
  if (!any(hit)) return(out)
  cells <- regmatches(lines, m)
  v <- rep(NA_character_, length(cells))
  has_v <- grepl("<v>", cells, fixed = TRUE)
  v[has_v] <- sub("^.*<v>(.*?)</v>.*$", "\\1", cells[has_v])
  is_s <- grepl('t="s"', cells, fixed = TRUE) & has_v
  if (any(is_s)) v[is_s] <- strings[as.integer(v[is_s]) + 1L]
  inl <- grepl('t="inlineStr"', cells, fixed = TRUE)
  if (any(inl)) v[inl] <- .md_unescape(sub("^.*<t[^>]*>(.*?)</t>.*$", "\\1", cells[inl]))
  out[hit] <- v
  out
}

# Every cell of one row, with its column letter. Used only for the header.
.md_row_cells <- function(line, strings) {
  cells <- regmatches(line, gregexpr("<c [^>]*/>|<c [^>]*>.*?</c>", line))[[1]]
  refs <- sub('^<c [^>]*r="([A-Z]+)[0-9]+".*$', "\\1", cells)
  v <- rep(NA_character_, length(cells))
  has_v <- grepl("<v>", cells, fixed = TRUE)
  v[has_v] <- sub("^.*<v>(.*?)</v>.*$", "\\1", cells[has_v])
  is_s <- grepl('t="s"', cells, fixed = TRUE) & has_v
  if (any(is_s)) v[is_s] <- strings[as.integer(v[is_s]) + 1L]
  list(ref = refs, value = v)
}

.md_unzip_member <- function(zip, member, dest) {
  suppressWarnings(system2("unzip", c("-p", shQuote(zip), shQuote(member)),
                           stdout = dest, stderr = FALSE))
  if (!file.exists(dest) || file.size(dest) == 0) {
    stop("could not extract ", member, " from ", basename(zip), call. = FALSE)
  }
  dest
}

# Insert a newline after every occurrence of `tag`, so a single-line XML
# document becomes line-oriented and can be read incrementally.
.md_split_on <- function(src, tag, dest) {
  system2("sed", c("-e", shQuote(paste0("s|", tag, "|", tag, "\\n|g")), shQuote(src)),
          stdout = dest, stderr = FALSE)
  dest
}

# The shared string table. An <si> may hold several <t> runs (rich text) which
# concatenate into one value, so this cannot simply grep for <t>. Chunks are
# collected into a list and unlisted once: repeatedly growing a character vector
# of ~800,000 elements is quadratic.
.md_shared_strings <- function(path) {
  lines_file <- .md_split_on(path, "</si>", paste0(path, ".lines"))
  con <- file(lines_file, "r"); on.exit(close(con))
  acc <- list()
  repeat {
    lines <- readLines(con, n = 200000L, warn = FALSE)
    if (!length(lines)) break
    lines <- lines[grepl("<si>", lines, fixed = TRUE)]
    if (!length(lines)) next
    acc[[length(acc) + 1L]] <- vapply(
      regmatches(lines, gregexpr("<t[^>]*>[^<]*</t>", lines)),
      function(ts) if (!length(ts)) "" else
        paste0(sub("^<t[^>]*>", "", sub("</t>$", "", ts)), collapse = ""),
      character(1))
  }
  .md_unescape(unlist(acc, use.names = FALSE))
}

.md_unescape <- function(x) {
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&apos;", "'", x, fixed = TRUE)
  gsub("&amp;", "&", x, fixed = TRUE)
}
