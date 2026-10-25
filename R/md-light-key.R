#' The light key ingests group spellings on
#'
#' When an ingest collapses a source's rows to one name per EIN, it groups them
#' on this key and keeps the most frequent raw spelling in each group
#' ([md_modal_sql()]). The key is deliberately light: it merges spellings that
#' differ only in how they are typed, and leaves everything else - misspellings,
#' abbreviations, word order - for the normalizer's derived columns. So
#' FOUNDATION and FOUNDAITON stay apart here.
#'
#' The steps, in order:
#' \enumerate{
#'   \item Accent marks are removed: É to E, ñ to n, ö to o.
#'   \item Letters that are not an accented form of another letter are written
#'     the way English text writes them: Ø to O, Ł to L, Đ to D, ı to i, Æ to
#'     AE, Œ to OE, ß to SS, Þ to TH.
#'   \item `&` becomes the word AND, so "A & B", "A&B" and "A AND B" are one.
#'   \item Uppercase.
#'   \item Tabs, newlines and no-break spaces become spaces.
#'   \item Every remaining character other than A-Z, 0-9 and space is deleted:
#'     "ST. MARY'S" is "ST MARYS".
#'   \item Runs of spaces become one; leading and trailing spaces go.
#' }
#'
#' Until 2026-10-25 steps 1-3 and 5 did not exist: accented and other non-ASCII
#' letters were deleted ("CAFÉ" became "CAF", "STRAßE" "STRAE"), `&` was deleted
#' while AND was kept, and a tab joined the words either side of it.
#'
#' Ingests compute the key in SQL through the macro `md_light_key(x)`
#' (installed by `.md_light_key_macro()`); this R function is the same rule, and
#' a test holds the two to identical output.
#'
#' @param x A character vector.
#' @return A character vector of keys; `NA` becomes `""`.
#' @export
md_light_key <- function(x) {
  .md_need("stringi", "md_light_key()")
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub("\\p{Mn}", "", stringi::stri_trans_nfd(enc2utf8(x)), perl = TRUE)
  x <- chartr(.md_lk_from, .md_lk_to, x)
  for (i in seq_along(.md_lk_multi)) {
    x <- gsub(names(.md_lk_multi)[i], .md_lk_multi[[i]], x, fixed = TRUE)
  }
  x <- gsub("&", " AND ", x, fixed = TRUE)
  x <- toupper(x)
  x <- gsub("[\t\n\v\f\r ]", " ", x, perl = TRUE)
  x <- gsub("[^A-Z0-9 ]", "", x, perl = TRUE)
  x <- gsub(" +", " ", x, perl = TRUE)
  trimws(x, whitespace = " ")
}

# Single letters mapped one to one, and letters that become two.
.md_lk_from <- "ØøŁłĐđı"
.md_lk_to   <- "OoLlDdi"
.md_lk_multi <- c("Æ" = "AE", "æ" = "ae", "Œ" = "OE", "œ" = "oe",
                  "ß" = "ss", "Þ" = "TH", "þ" = "th")

# Install md_light_key(x) in a connection. Temporary, like the identity macros:
# the rule lives in this file, not in the database.
.md_light_key_macro <- function(con) {
  s <- "strip_accents(coalesce(CAST(x AS VARCHAR), ''))"
  s <- sprintf("translate(%s, '%s', '%s')", s, .md_lk_from, .md_lk_to)
  for (i in seq_along(.md_lk_multi)) {
    s <- sprintf("replace(%s, '%s', '%s')", s, names(.md_lk_multi)[i], .md_lk_multi[[i]])
  }
  s <- sprintf("upper(replace(%s, '&', ' AND '))", s)
  s <- sprintf("regexp_replace(%s, '[\\t\\n\\v\\f\\r\\x{a0}]', ' ', 'g')", s)
  s <- sprintf("trim(regexp_replace(regexp_replace(%s, '[^A-Z0-9 ]', '', 'g'), ' +', ' ', 'g'))", s)
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP MACRO md_light_key(x) AS %s", s))
  invisible(con)
}
