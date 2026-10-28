#' The light key ingests group spellings on
#'
#' When an ingest collapses a source's rows to one name per EIN, it groups them
#' on this key and keeps the most frequent raw spelling in each group
#' ([md_modal_sql()]). The key is deliberately light: it merges spellings that
#' differ only in how they are typed, and leaves everything else - misspellings,
#' abbreviations, word order - for the normalizer's derived columns. So
#' FOUNDATION and FOUNDAITON stay apart here.
#'
#' The rule is npmatch's own name cleaning (`.np_basic_clean()`), so a key
#' built here and a key npmatch builds for a query agree. The steps, in order:
#' \enumerate{
#'   \item Accent marks are removed: É to E, ñ to n, ö to o.
#'   \item Letters that are not an accented form of another letter are written
#'     the way English text writes them: Ø to O, Ł to L, Đ to D, ı to i, Æ to
#'     AE, Œ to OE, ß and ẞ to SS, Þ to TH (npmatch's `.np_special_letters`).
#'   \item `&` becomes the word AND, so "A & B", "A&B" and "A AND B" are one.
#'   \item Uppercase.
#'   \item Joiners are **deleted**: every apostrophe (' ‘ ’ ʼ ´ `) and any
#'     period between two letters or digits. "BO'S PLACE" is "BOS PLACE" and
#'     "F.I.N.D." is "FIND", as the BMF holds them. A period that already
#'     separates words keeps its break: "ST. LUKES" is "ST LUKES".
#'   \item Every other character outside A-Z and 0-9 becomes a **space**:
#'     punctuation, tabs and newlines, and any non-Latin character. So
#'     "WINSTON-SALEM", "A/B" and "SMITH,JONES" keep two words each.
#'   \item Runs of spaces become one; leading and trailing spaces go.
#' }
#'
#' History. Until 2026-10-25 (morning) steps 1-3 did not exist and every
#' non-alphanumeric character was deleted: "CAFÉ" became "CAF", `&` vanished
#' while AND was kept, and a tab joined two words. The first fix kept deletion
#' for punctuation, which glued "WINSTON-SALEM" into one word where npmatch
#' keeps two; steps 5-6 now follow npmatch exactly.
#'
#' One known residual: npmatch transliterates with ICU's Latin-ASCII, which also
#' spells out rarer forms (ligatures such as "ﬁ", for example). SQL has no
#' Latin-ASCII, so here those become a space. They are vanishingly rare in
#' organisation names.
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
  x <- gsub(.md_lk_apostrophes, "", x, perl = TRUE)
  # a period between two alphanumerics, twice: each pass takes every other
  # period of a chain like F.I.N.D, and RE2 (the SQL side) has no lookaround
  for (i in 1:2) x <- gsub(.md_lk_joining_period, "\\1\\2", x, perl = TRUE)
  x <- gsub("[^A-Z0-9 ]", " ", x, perl = TRUE)
  x <- gsub(" +", " ", x, perl = TRUE)
  trimws(x, whitespace = " ")
}

# Single letters mapped one to one, and letters that become two. The same
# letters as npmatch's .np_special_letters, plus the dotless i, which npmatch's
# Latin-ASCII step handles and SQL's strip_accents() does not.
# Written as \u escapes so the code stays ASCII (R CMD check); the letters are,
# in order, O-slash, L-stroke, D-stroke (each upper then lower) and dotless i.
.md_lk_from <- "\u00d8\u00f8\u0141\u0142\u0110\u0111\u0131"
.md_lk_to   <- "OoLlDdi"
# AE, ae, OE, oe ligatures; sharp s, capital sharp s; thorn upper and lower
.md_lk_multi <- c("\u00c6" = "AE", "\u00e6" = "ae", "\u0152" = "OE", "\u0153" = "oe",
                  "\u00df" = "ss", "\u1e9e" = "SS", "\u00de" = "TH", "\u00fe" = "th")
# npmatch's .np_strip_joiners(): apostrophes, and a period inside a token.
# The class is ' and the left and right single quotes, modifier apostrophe,
# acute accent and backtick.
.md_lk_apostrophes <- "['\u2018\u2019\u02bc\u00b4`]"
.md_lk_joining_period <- "([A-Z0-9])[.]([A-Z0-9])"

# Install md_light_key(x) in a connection. Temporary, like the identity macros:
# the rule lives in this file, not in the database.
.md_light_key_macro <- function(con) {
  s <- "strip_accents(coalesce(CAST(x AS VARCHAR), ''))"
  s <- sprintf("translate(%s, '%s', '%s')", s, .md_lk_from, .md_lk_to)
  for (i in seq_along(.md_lk_multi)) {
    s <- sprintf("replace(%s, '%s', '%s')", s, names(.md_lk_multi)[i], .md_lk_multi[[i]])
  }
  s <- sprintf("upper(replace(%s, '&', ' AND '))", s)
  # the class holds a literal ', doubled inside the SQL string
  s <- sprintf("regexp_replace(%s, '%s', '', 'g')", s, gsub("'", "''", .md_lk_apostrophes, fixed = TRUE))
  for (i in 1:2) s <- sprintf("regexp_replace(%s, '%s', '\\1\\2', 'g')", s, .md_lk_joining_period)
  s <- sprintf("trim(regexp_replace(regexp_replace(%s, '[^A-Z0-9 ]', ' ', 'g'), ' +', ' ', 'g'))", s)
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP MACRO md_light_key(x) AS %s", s))
  invisible(con)
}
