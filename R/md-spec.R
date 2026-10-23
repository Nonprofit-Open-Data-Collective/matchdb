#' Describe a reference: which EINs, which names, which addresses
#'
#' A spec is the whole definition of a compiled reference (`PLAN.md` section
#' 5). It is small, serialisable and hashed: two references with the same
#' `spec_hash` were selected the same way. [md_compile()] turns it into the
#' frame npmatch matches against.
#'
#' @section The two selection axes:
#' `layers` chooses **which EINs** can be matched (`PLAN.md` section 3). Every
#' EIN has exactly one layer, so a union of layers is a clean union of EINs.
#' `names` and `addresses` choose **which strings** those EINs carry, by
#' variant class. An EIN in an active-BMF layer also has names from its own
#' filings and from Schedule I; `names` decides which of those count.
#'
#' `in_care_of` is not a selectable name class: it names someone other than the
#' organisation (a person, an agent or a parent). Its organisational content is
#' in the `care_of_network` clusters ([md_build_clusters()]).
#'
#' @section Filters that keep statistics exact:
#' Corpus statistics for a spec are sums over precomputed cells
#' (layer x variant class x corroboration band; [md_build_stats()]). A filter
#' that cuts across cells would break that, so `min_corroborators` - which
#' applies to `observed` names only - must be a band edge: 1, 2, 5 or 20.
#' `max_names` and `drop_before_year` do cut across cells; a spec using them is
#' still compiled exactly, but its statistics are computed directly from the
#' selected rows rather than summed from cells, and the report says so.
#'
#' @param layers Layers to include; see [md_layers()].
#' @param names Name variant classes to include.
#' @param addresses Address variant classes to include.
#' @param sources Optional: only strings from these sources (`bmf`, `efile990`,
#'   `f1023ez`, `schedi`, `schedr`, `meta_address`). `NULL` takes every source.
#'   Since the e-file and 1023-EZ ingests, `legal` and `mailing` are no longer
#'   BMF-only, so a reference meant to reproduce a BMF frame needs
#'   `sources = "bmf"`. Names are collapsed across sources, so a source filter
#'   cuts across the statistics cells, and those statistics are computed
#'   directly.
#' @param min_corroborators Minimum distinct filers behind an `observed` name:
#'   1, 2, 5 or 20.
#' @param max_names Optional cap per class, as a named integer vector, e.g.
#'   `c(observed = 3)`. Classes not named are uncapped. Capping per class, not
#'   overall, keeps a legal name from being displaced by aliases (section 7c).
#' @param max_addresses Optional cap on first-party addresses per EIN.
#' @param drop_before_year Optional: drop names and addresses last seen before
#'   this year. Rows with no year (most BMF rows) are kept.
#' @param dba_as `"column"` puts each EIN's best DBA in the `dba` field of its
#'   legal-name rows, the shape npmatch's BMF reference has; further DBAs become
#'   rows. `"row"` makes every DBA its own row.
#' @param label Optional name for the spec, e.g. `"active-observed"`. Not part of
#'   the hash.
#' @return An object of class `md_spec`.
#' @export
md_spec <- function(layers = "bmf_active",
                    names = c("legal", "dba"),
                    addresses = "mailing",
                    sources = NULL,
                    min_corroborators = 1L,
                    max_names = NULL,
                    max_addresses = NULL,
                    drop_before_year = NULL,
                    dba_as = c("column", "row"),
                    label = NULL) {
  dba_as <- match.arg(dba_as)
  bad <- function(x, ok, what) {
    x <- unique(as.character(x))
    if (!length(x)) stop(what, " must name at least one value", call. = FALSE)
    if (any(!x %in% ok)) {
      stop("unknown ", what, ": ", paste(setdiff(x, ok), collapse = ", "),
           ". Allowed: ", paste(ok, collapse = ", "), call. = FALSE)
    }
    sort(x)
  }
  if ("in_care_of" %in% names) {
    stop("in_care_of is not a name of the organisation: it names a person, an ",
         "agent or a parent. Use the care_of_network clusters instead.", call. = FALSE)
  }
  layers <- bad(layers, md_layers(), "layers")
  names <- bad(names, setdiff(md_name_classes(), "in_care_of"), "names")
  addresses <- bad(addresses, md_address_classes(), "addresses")
  if (!is.null(sources)) {
    sources <- bad(sources, union(base::names(md_name_sources()),
                                  base::names(md_address_sources())), "sources")
  }
  min_corroborators <- as.integer(min_corroborators)
  if (length(min_corroborators) != 1L || !min_corroborators %in% .md_corrob_edges) {
    stop("min_corroborators must be a band edge: ",
         paste(.md_corrob_edges, collapse = ", "),
         " - so a spec stays a union of precomputed cells", call. = FALSE)
  }
  if (!is.null(max_names)) {
    if (is.null(base::names(max_names)) || any(!base::names(max_names) %in% names)) {
      stop("max_names must be named by selected name classes", call. = FALSE)
    }
    max_names <- stats::setNames(as.integer(max_names), base::names(max_names))
    max_names <- max_names[order(base::names(max_names))]
    if (any(is.na(max_names) | max_names < 1L)) stop("max_names must be >= 1", call. = FALSE)
  }
  if (!is.null(max_addresses)) max_addresses <- as.integer(max_addresses)
  if (!is.null(drop_before_year)) drop_before_year <- as.integer(drop_before_year)

  spec <- list(layers = layers, names = names, addresses = addresses, sources = sources,
               min_corroborators = min_corroborators, max_names = max_names,
               max_addresses = max_addresses, drop_before_year = drop_before_year,
               dba_as = dba_as)
  structure(c(spec, list(label = label, spec_hash = .md_spec_hash(spec))),
            class = "md_spec")
}

#' @export
print.md_spec <- function(x, ...) {
  cat("<md_spec", if (!is.null(x$label)) paste0(" ", x$label), "> ", x$spec_hash, "\n", sep = "")
  cat("  layers:    ", paste(x$layers, collapse = ", "), "\n")
  cat("  names:     ", paste(x$names, collapse = ", "),
      if (x$min_corroborators > 1L) sprintf("(observed: %d+ filers)", x$min_corroborators), "\n")
  cat("  addresses: ", paste(x$addresses, collapse = ", "), "\n")
  if (!is.null(x$sources)) cat("  sources:   ", paste(x$sources, collapse = ", "), "\n")
  if (!is.null(x$max_names)) {
    cat("  max_names: ", paste(sprintf("%s=%d", base::names(x$max_names), x$max_names),
                               collapse = ", "), "\n")
  }
  if (!is.null(x$max_addresses)) cat("  max_addresses:", x$max_addresses, "\n")
  if (!is.null(x$drop_before_year)) cat("  drop_before_year:", x$drop_before_year, "\n")
  cat("  dba_as:    ", x$dba_as, "\n")
  invisible(x)
}

# Corroboration band edges: the bands build-schedi-db.R reports (1, 2-4, 5-19,
# 20+). min_corroborators must be one of them (PLAN.md section 6c).
.md_corrob_edges <- c(1L, 2L, 5L, 20L)

# The band label of an observed name's n_corroborators, as SQL. First-party
# names have no band.
.md_band_sql <- function(class_col, n_col) {
  sprintf("CASE WHEN %s <> 'observed' THEN 'first_party'
                WHEN coalesce(%s, 1) >= 20 THEN '20+'
                WHEN coalesce(%s, 1) >= 5 THEN '5-19'
                WHEN coalesce(%s, 1) >= 2 THEN '2-4'
                ELSE '1' END", class_col, n_col, n_col, n_col)
}

# The bands a spec's min_corroborators admits.
.md_bands_for <- function(min_corroborators) {
  all <- c(`1` = 1L, `2-4` = 2L, `5-19` = 5L, `20+` = 20L)
  c("first_party", base::names(all)[all >= min_corroborators])
}

# md5 of a canonical serialisation: fields in a fixed order, values sorted,
# NULLs written as empty. The label is not part of it.
.md_spec_hash <- function(spec) {
  f <- function(v) if (is.null(v)) "" else if (!is.null(base::names(v)))
    paste(base::names(v), v, sep = "=", collapse = ",") else paste(v, collapse = ",")
  keys <- c("layers", "names", "addresses", "sources", "min_corroborators", "max_names",
            "max_addresses", "drop_before_year", "dba_as")
  s <- paste0("md_spec/1;", paste(keys, vapply(spec[keys], f, character(1)),
                                  sep = ":", collapse = ";"))
  substr(.md_md5_string(s), 1, 16)
}
