#' Canonical text and content-hash ids
#'
#' Phase 5 (`dev/IDENTITY.md` §3) identifies every name, address, observation
#' and release by an md5 of what the source wrote, so anyone can recompute an id
#' from the raw file and get the same value on any machine. These functions are
#' the R side of that recipe. Ingest computes the same ids in SQL with the
#' macros [md_identity_macros()] installs; a test holds the two to identical
#' output.
#'
#' @section `md_canon()`:
#' The only change made to a field before hashing:
#' \enumerate{
#'   \item `NA` / `NULL` becomes `""`.
#'   \item Unicode NFC, so a precomposed and a decomposed accent are one string.
#'   \item Every run of control characters, spaces and no-break spaces
#'     (`\\x01`-`\\x20`, `\\x7f`, `\\x{a0}`) becomes one space. Tabs and newlines
#'     are whitespace in the data; the other control characters are noise, and
#'     folding them in means the field separator `\\x1f` can never occur inside
#'     a canonical field.
#'   \item Leading and trailing spaces are dropped.
#' }
#' There is **no** case folding and no punctuation stripping: the canonical
#' string is what the source wrote, apart from whitespace. Matching on
#' case-insensitive keys is the normalizer's job, in the derived columns.
#'
#' @section The recipe:
#' `id = md5(tag \\x1f canon(field_1) \\x1f canon(field_2) ...)`, as 32
#' lowercase hex characters. The tag names the recipe and its version
#' ([md_id_recipes()]). Changing what goes into an id means a new tag, never an
#' edit to an old one.
#'
#' Ids are kept as hex strings, not integers: DuckDB's R client converts
#' `HUGEINT` to `double` by default, which would silently destroy a 128-bit id.
#'
#' @param x A character vector (other types are coerced with `as.character()`).
#' @param tag A recipe tag from [md_id_recipes()].
#' @param ... Fields, each a vector of the same length (or length 1).
#' @return A character vector.
#' @name md_identity
NULL

# One pattern for both engines. PCRE (R, perl = TRUE) and RE2 (DuckDB) read
# these escapes identically; writing it once is what keeps them in step.
.md_canon_ws <- "[\\x01-\\x20\\x7f\\x{a0}]+"
.md_id_sep <- "\x1f"

#' @rdname md_identity
#' @export
md_canon <- function(x) {
  .md_need("stringi", "md_canon()")
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- stringi::stri_trans_nfc(enc2utf8(x))
  x <- gsub(.md_canon_ws, " ", x, perl = TRUE)
  x <- sub("^ ", "", sub(" $", "", x))
  x
}

#' @rdname md_identity
#' @export
md_hash_id <- function(tag, ...) {
  .md_need("digest", "md_hash_id()")
  .md_check_tag(tag, ...length())
  fields <- lapply(list(...), md_canon)
  key <- do.call(paste, c(list(tag), fields, sep = .md_id_sep))
  vapply(enc2utf8(key), digest::digest, character(1),
         algo = "md5", serialize = FALSE, USE.NAMES = FALSE)
}

#' @rdname md_identity
#' @param name_raw A name as the source wrote it.
#' @export
md_name_text_id <- function(name_raw) md_hash_id("name.v1", name_raw)

#' @rdname md_identity
#' @param street,unit,city,state,zip5,zip4 Address fields as the source wrote
#'   them. A source without a separate unit line passes `NA`.
#' @export
md_address_text_id <- function(street, unit, city, state, zip5, zip4) {
  md_hash_id("addr.v1", street, unit, city, state, zip5, zip4)
}

#' @rdname md_identity
#' @param source,version,partition A pinned release. `partition` is the tax year
#'   for a year-partitioned source and `NA` otherwise.
#' @export
md_release_id <- function(source, version, partition = NA) {
  md_hash_id("rel.v1", source, version, partition)
}

#' The id recipes
#'
#' One row per recipe tag: what it identifies and the fields that go into it, in
#' order. Append-only, like [md_layers()]: a recipe is never edited, only
#' superseded by a new tag, because an edit would silently change what every
#' stored id of that tag refers to.
#'
#' Observation ids come in two shapes ([md_ledger]): a spell id for snapshot
#' sources, and a row id for every other kind. The row id hashes the row's
#' content, so a corrected value in a re-released filing is a new observation
#' rather than an update a diff cannot see.
#'
#' @return A data frame with `tag`, `identifies`, `fields`.
#' @export
md_id_recipes <- function() {
  data.frame(
    tag = c("name.v1", "addr.v1", "rel.v1", "row.v1", "obs.v1/row", "obs.v1/spell"),
    identifies = c(
      "a distinct name string, whatever EIN or source wrote it",
      "a distinct address as written",
      "one pinned file or partition actually read",
      "the content of one observation, within its record",
      "one occurrence of a row (series, mentions, cache, seed)",
      "one spell of a snapshot value: an unbroken run of releases with the same value"),
    fields = c(
      "name_raw",
      "street, unit, city, state, zip5, zip4",
      "source, version, partition",
      "ein, role, name_text_id, address_text_id, asserted_by, period",
      "source, record_key, row_hash, occurrence",
      "source, ein, role, name_text_id, address_text_id, first_seen"),
    stringsAsFactors = FALSE)
}

#' Install the id macros in a DuckDB connection
#'
#' Defines SQL macros that compute exactly what the R functions in
#' [md_identity] compute, so ingest can hash millions of rows in the database:
#'
#' \describe{
#'   \item{`md_canon(x)`}{[md_canon()].}
#'   \item{`md_hash_id_1(tag, a)` ... `md_hash_id_8(tag, a, ..., h)`}{[md_hash_id()]
#'     with that many fields. DuckDB macros have fixed arity, so there is one per
#'     field count.}
#'   \item{`md_name_text_id(name_raw)`}{[md_name_text_id()].}
#'   \item{`md_address_text_id(street, unit, city, state, zip5, zip4)`}{[md_address_text_id()].}
#'   \item{`md_release_id(source, version, partition)`}{[md_release_id()].}
#' }
#'
#' Temporary macros, so they live as long as the connection and are never
#' written into `MATCHDB.duckdb`: the recipe's definition stays in this file.
#'
#' @param con A DuckDB connection.
#' @return `con`, invisibly.
#' @export
md_identity_macros <- function(con) {
  DBI::dbExecute(con, sprintf(
    "CREATE OR REPLACE TEMP MACRO md_canon(x) AS
       trim(regexp_replace(nfc_normalize(coalesce(CAST(x AS VARCHAR), '')),
                           '%s', ' ', 'g'), ' ')", .md_canon_ws))
  for (k in 1:8) {
    args <- letters[1:k]
    DBI::dbExecute(con, sprintf(
      "CREATE OR REPLACE TEMP MACRO md_hash_id_%d(tag, %s) AS
         md5(tag || chr(31) || %s)",
      k, paste(args, collapse = ", "),
      paste(sprintf("md_canon(%s)", args), collapse = " || chr(31) || ")))
  }
  DBI::dbExecute(con,
    "CREATE OR REPLACE TEMP MACRO md_name_text_id(name_raw) AS
       md_hash_id_1('name.v1', name_raw)")
  DBI::dbExecute(con,
    "CREATE OR REPLACE TEMP MACRO md_address_text_id(street, unit, city, state, zip5, zip4) AS
       md_hash_id_6('addr.v1', street, unit, city, state, zip5, zip4)")
  DBI::dbExecute(con,
    "CREATE OR REPLACE TEMP MACRO md_release_id(source, version, part) AS
       md_hash_id_3('rel.v1', source, version, part)")
  invisible(con)
}

.md_check_tag <- function(tag, n_fields) {
  known <- c("name.v1" = 1L, "addr.v1" = 6L, "rel.v1" = 3L)
  if (length(tag) != 1L || !nzchar(tag)) stop("tag must be one recipe tag", call. = FALSE)
  if (tag %in% names(known) && known[[tag]] != n_fields) {
    stop(sprintf("recipe %s takes %d field(s), not %d", tag, known[[tag]], n_fields),
         call. = FALSE)
  }
  if (n_fields < 1L || n_fields > 8L) stop("an id takes 1 to 8 fields", call. = FALSE)
  invisible(TRUE)
}

.md_need <- function(pkg, what) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop(what, " needs the '", pkg, "' package", call. = FALSE)
  }
}
