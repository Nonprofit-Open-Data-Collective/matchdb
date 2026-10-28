#' Compile a spec into the reference frame npmatch matches against
#'
#' Turns an [md_spec()] into the wide `np_reference` frame: one row per EIN x
#' selected name x paired address, with npmatch's derived columns, `.ein`,
#' `.id` and `active` (`PLAN.md` section 6). It also returns the corpus
#' statistics for exactly that selection, and a report of what the selection
#' emits and what it leaves out.
#'
#' @section Where the rows come from:
#' Names come from `name_compact`: one row per `(ein, name_key)`, collapsed
#' across sources, without in-care-of names or guarded observed rows. Addresses
#' come from `address` and `address_derived`, collapsed here over the selected
#' classes to one row per place - `address_compact` has no variant class to
#' select on.
#'
#' @section The pairing rule:
#' Section 8: a third party wrote an observed name *together with* an address,
#' so an `observed` name pairs with the observed addresses written beside it
#' (`address.name_id`), and only first-party names cross with first-party
#' addresses. Emission is then roughly names + addresses per EIN, not their
#' product. An observed name with no address of its own pairs with the EIN's
#' first-party addresses; an EIN with no selected address still gets one row
#' per name, with the address fields empty.
#'
#' @section Derived columns:
#' Every column [npmatch::np_normalize()] adds is a function of one input field,
#' and [md_build_derived()] stores all of them. `derive = "stored"` (the
#' default) gives each row the stored columns of a row holding exactly its
#' strings - the name row with its spelling, the address row with its street,
#' zip and state, the DBA row with its DBA - so the frame is what
#' `np_normalize()` would build, without running it. A sample of `check_rows`
#' rows is then re-normalized and compared, and any difference is an error.
#' `derive = "normalize"` runs `np_normalize()` on the whole frame instead.
#'
#' Either way the installed normalizer must be the one that built
#' `name_derived`, because `name_compact`'s keys came from it.
#'
#' @section Statistics:
#' Two kinds, both returned:
#' \describe{
#'   \item{`name_freq`, `token_idf`}{npmatch's own, over the emitted frame -
#'     what [npmatch::np_cascade()] uses today. A name repeated once per paired
#'     address counts once per row.}
#'   \item{`name_eins`, `token_df`, `n_name_rows`}{over names, one per
#'     `(ein, name_key)`. For a spec without a cross-cutting filter these are
#'     summed from [md_build_stats()]'s cells; otherwise computed directly from
#'     the selected names. `report$stats_method` says which.}
#' }
#'
#' @section The report:
#' Shape: rows by name and address class, rows per EIN, EINs with no address.
#' Absence (section 8a): for each cluster type, how many selected EINs have a
#' family member the selection leaves out. A thin reference cannot see the
#' sibling it is missing, and auto-accepts against whichever member it holds;
#' this is the count that says how often that can happen.
#'
#' @param spec An [md_spec()].
#' @param con A connection from [md_db()], or from [md_tranche_db()] holding
#'   the files the spec needs.
#' @param derive `"stored"` (the npmatch frame from stored columns),
#'   `"normalize"` (the same frame, by running `np_normalize()`) or `"none"`
#'   (raw fields only).
#' @param check_rows For `derive = "stored"`, how many rows to re-normalize and
#'   compare. 0 skips the check.
#' @param max_rows Row budget. Emission is counted before anything is
#'   materialised, and a spec over budget is an error naming the classes
#'   responsible, rather than a reference that costs far more than planned.
#' @return An object of class `md_reference`: `reference` (the frame),
#'   `name_freq`, `token_idf`, `name_eins`, `token_df`, `n_name_rows`,
#'   `report`, `spec` and `stamp`.
#' @export
md_compile <- function(spec, con = NULL, derive = c("stored", "normalize", "none"),
                       max_rows = 2e7, check_rows = 2000L) {
  if (!inherits(spec, "md_spec")) stop("spec must come from md_spec()", call. = FALSE)
  derive <- match.arg(derive)
  own <- is.null(con)
  if (own) { con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE) }
  .md_tranche_check(con, spec)      # a connection from md_tranche_db() holding every file needed
  msg <- function(...) message(sprintf(...))
  timed <- getOption("matchdb.compile_timing", FALSE)
  tick <- function(t0, sql) if (timed) message(sprintf("  [%5.1fs] %s", as.numeric(
    difftime(Sys.time(), t0, units = "secs")), substr(gsub("\\s+", " ", sql), 1, 60)))
  q <- function(sql) { t0 <- Sys.time(); r <- DBI::dbGetQuery(con, sql); tick(t0, sql); r }
  x <- function(sql) { t0 <- Sys.time(); DBI::dbExecute(con, sql); tick(t0, sql); invisible() }
  lit <- function(v) paste0("'", gsub("'", "''", v), "'", collapse = ", ")
  stamp <- .md_compile_stamp(con, spec)

  ## ---- which EINs ----------------------------------------------------------------
  x(sprintf("CREATE OR REPLACE TEMP TABLE cp_ein AS
             SELECT ein, layer, active FROM entity WHERE layer IN (%s)", lit(spec$layers)))

  ## ---- which names ---------------------------------------------------------------
  # Collapsed here, from the raw rows of the selected classes and sources, by
  # name_compact's own rules (one row per (ein, name_key), the strongest class,
  # the most common spelling; no in-care-of, empty or guarded rows). With every
  # source selected this is name_compact itself; with fewer, the spelling is the
  # selected sources' own - which a BMF-only reference needs.
  year_ok <- function(col) if (is.null(spec$drop_before_year)) "TRUE" else
    sprintf("(%s IS NULL OR %s >= %d)", col, col, spec$drop_before_year)
  src_ok <- function(col) if (is.null(spec$sources)) "TRUE" else
    sprintf("%s IN (%s)", col, lit(spec$sources))
  # The class is decided over every class, as name_compact decides it - a key
  # both legal and observed is legal - and only then filtered by the spec. That
  # keeps each (ein, name_key) in the one stat cell md_build_stats() put it in.
  rank_case <- gsub("variant_class", "n.variant_class", .md_variant_rank_case())
  x(sprintf("CREATE OR REPLACE TEMP TABLE cp_name0 AS
    SELECT n.ein, n.name_id, d.name_key, n.name_raw, %s AS vrank,
           n.n_corroborators, n.last_year, n.n_obs
    FROM name n JOIN cp_ein e USING (ein)
    JOIN name_derived d ON CAST(d.name_id AS BIGINT) = n.name_id
    WHERE n.variant_class <> 'in_care_of' AND d.name_key <> '' AND %s AND NOT %s",
    rank_case, src_ok("n.source"), .md_guarded_sql(con, "n")))
  x(sprintf("CREATE OR REPLACE TEMP TABLE cp_name AS
    WITH agg AS (
      SELECT ein, name_key, min(vrank) AS vrank, max(n_corroborators) AS n_corroborators,
             max(last_year) AS last_year, sum(n_obs) AS n_obs
      FROM cp_name0 GROUP BY 1, 2
    ), %s
    SELECT a.ein, a.name_key, m.name_raw, rp.name_id, r.variant_class, e.layer,
           %s AS band, a.n_corroborators, a.last_year, a.n_obs,
           row_number() OVER (PARTITION BY a.ein, r.variant_class
             ORDER BY a.n_corroborators DESC NULLS LAST, a.last_year DESC NULLS LAST,
                      a.n_obs DESC NULLS LAST, a.name_key) AS class_rank
    FROM agg a JOIN cp_ein e USING (ein)
    JOIN modal_name_raw m ON m.ein = a.ein AND m.name_key = a.name_key AND m.rk = 1
    -- a stored row with exactly this spelling, whose derived columns it takes
    JOIN (SELECT c.ein, c.name_key, min(c.name_id) AS name_id FROM cp_name0 c
          JOIN modal_name_raw mm ON mm.ein = c.ein AND mm.name_key = c.name_key
           AND mm.rk = 1 AND mm.name_raw = c.name_raw GROUP BY 1, 2) rp
      ON rp.ein = a.ein AND rp.name_key = a.name_key
    JOIN (SELECT * FROM (VALUES %s) v(vrank, variant_class)) r USING (vrank)
    WHERE r.variant_class IN (%s)
      AND (r.variant_class <> 'observed' OR coalesce(a.n_corroborators, 1) >= %d)
      AND %s",
    # the spelling is voted on by the rows of the key's strongest class only: a
    # dba that normalizes like the legal name must not lend it its spelling
    md_modal_sql("(SELECT * FROM (SELECT *, min(vrank) OVER (PARTITION BY ein, name_key) AS kv
                   FROM cp_name0) WHERE vrank = kv)", c("ein", "name_key"), "name_raw"),
    .md_band_sql("r.variant_class", "a.n_corroborators"),
    paste(sprintf("(%s, '%s')", base::names(.md_rank_to_variant), .md_rank_to_variant),
          collapse = ", "),
    lit(spec$names), spec$min_corroborators, year_ok("a.last_year")))
  x("DROP TABLE cp_name0")
  if (!is.null(spec$max_names)) {
    for (k in base::names(spec$max_names)) {
      x(sprintf("DELETE FROM cp_name WHERE variant_class = '%s' AND class_rank > %d",
                k, spec$max_names[[k]]))
    }
  }
  # dba_as = "column": the best DBA rides in the dba field of legal rows. It is
  # taken from the raw DBA rows, not from cp_name, because a DBA can share its
  # name_key with the legal name - npmatch strips FUND and FOUNDATION alike, so
  # ACME FUND and ACME FOUNDATION INC are both ACME - and a BMF frame still
  # carries that DBA string.
  use_dba_col <- spec$dba_as == "column" && "dba" %in% spec$names
  x(sprintf("CREATE OR REPLACE TEMP TABLE cp_dba AS
    SELECT ein, dba, dba_key, dba_name_id FROM (
      SELECT n.ein, n.name_raw AS dba, d.name_key AS dba_key, n.name_id AS dba_name_id,
             row_number() OVER (PARTITION BY n.ein
               ORDER BY n.n_corroborators DESC NULLS LAST, n.last_year DESC NULLS LAST,
                        n.n_obs DESC NULLS LAST, n.name_raw) AS rk
      FROM name n JOIN cp_ein e USING (ein)
      JOIN name_derived d ON CAST(d.name_id AS BIGINT) = n.name_id
      WHERE %s AND n.variant_class = 'dba' AND coalesce(n.name_raw, '') <> ''
        AND %s AND NOT %s)
    WHERE rk = 1",
    if (use_dba_col) "TRUE" else "FALSE", src_ok("n.source"), .md_guarded_sql(con, "n")))

  ## ---- which addresses -----------------------------------------------------------
  addr_year <- if (is.null(spec$drop_before_year)) "TRUE" else
    sprintf("(try_cast(substr(a.last_vintage, 1, 4) AS INT) IS NULL OR
              try_cast(substr(a.last_vintage, 1, 4) AS INT) >= %d)", spec$drop_before_year)
  # Plain equality joins only, ids cast to one type: a filter inside a LEFT
  # JOIN's ON clause, or a DOUBLE-to-BIGINT comparison, turns DuckDB's hash
  # join into a pairwise one - measured at 1,261 s for this statement.
  # the second address line, where the address table keeps it: the stored
  # derived columns were computed with it, so the frame must carry it too
  unit_sql <- if ("unit_raw" %in% DBI::dbListFields(con, "address"))
    "coalesce(a.unit_raw, '')" else "''"
  x(sprintf("CREATE OR REPLACE TEMP TABLE cp_addr_sel AS
    SELECT a.address_id, a.ein, a.name_id, coalesce(a.zip5, '') AS zip5,
           a.variant_class = 'observed' AS observed,
           CASE a.variant_class WHEN 'mailing' THEN 1 WHEN 'principal' THEN 2
                WHEN 'historical' THEN 3 ELSE 4 END AS class_rank,
           a.variant_class, a.street_raw, %s AS unit_raw, a.city_raw, a.state, a.zip_plus4,
           a.county, try_cast(substr(a.last_vintage, 1, 4) AS INT) AS ly,
           coalesce(a.n_obs, 1) AS n_obs
    FROM address a JOIN cp_ein e USING (ein)
    WHERE a.variant_class IN (%s) AND %s AND %s",
    unit_sql, lit(spec$addresses), addr_year, src_ok("a.source")))
  x("CREATE OR REPLACE TEMP TABLE cp_addr_link AS
     SELECT s.address_id, nd.name_key AS link_key
     FROM cp_addr_sel s JOIN name_derived nd ON CAST(nd.name_id AS BIGINT) = s.name_id
     WHERE s.observed")
  x("CREATE OR REPLACE TEMP TABLE cp_addr_raw AS
    SELECT s.* EXCLUDE (name_id), d.street_key, l.link_key
    FROM cp_addr_sel s
    JOIN address_derived d ON CAST(d.address_id AS BIGINT) = s.address_id
    LEFT JOIN cp_addr_link l ON l.address_id = s.address_id
    -- no street is fine when the ZIP or state still places it
    WHERE coalesce(d.street_key, '') <> '' OR s.zip5 <> '' OR coalesce(s.state, '') <> ''")
  x("DROP TABLE cp_addr_sel"); x("DROP TABLE cp_addr_link")
  # one row per place: the most common spelling, the strongest class
  x("CREATE OR REPLACE TEMP TABLE cp_addr AS
    WITH sp AS (
      SELECT ein, street_key, zip5, observed, coalesce(link_key, '') AS link_key,
             street_raw, unit_raw, city_raw, state, zip_plus4, county, count(*) AS n,
             min(address_id) AS address_id  -- a stored row with exactly this spelling
      FROM cp_addr_raw GROUP BY ALL
    ), best AS (
      SELECT * FROM (SELECT *, row_number() OVER (
               PARTITION BY ein, street_key, zip5, observed, link_key
               ORDER BY n DESC, street_raw, unit_raw, city_raw, state, zip_plus4, county) AS rk
             FROM sp)
      WHERE rk = 1
    ), agg AS (
      SELECT ein, street_key, zip5, observed, coalesce(link_key, '') AS link_key,
             min(class_rank) AS class_rank, max(ly) AS ly, sum(n_obs) AS n_obs,
             arg_min(variant_class, class_rank) AS address_class
      FROM cp_addr_raw GROUP BY 1, 2, 3, 4, 5
    )
    SELECT a.*, b.street_raw, b.unit_raw, b.city_raw, b.state, b.zip_plus4, b.county,
           b.address_id,
           row_number() OVER (PARTITION BY a.ein, a.observed
             ORDER BY a.class_rank, a.ly DESC NULLS LAST, a.n_obs DESC,
                      a.street_key, a.zip5, a.link_key) AS addr_rank
    FROM agg a JOIN best b USING (ein, street_key, zip5, observed, link_key)")
  if (!is.null(spec$max_addresses)) {
    x(sprintf("DELETE FROM cp_addr WHERE NOT observed AND addr_rank > %d", spec$max_addresses))
  }

  ## ---- pair, count, then emit ----------------------------------------------------
  # In column mode the DBA already in the dba field is not also a row.
  first_party_names <- if (use_dba_col)
    "n.variant_class <> 'observed' AND NOT (n.variant_class = 'dba' AND EXISTS (
       SELECT 1 FROM cp_dba b WHERE b.ein = n.ein AND b.dba_key = n.name_key))"
  else "n.variant_class <> 'observed'"
  x(sprintf("CREATE OR REPLACE TEMP TABLE cp_pair AS
    WITH fp AS (SELECT * FROM cp_addr WHERE NOT observed),
    fpn AS (SELECT n.* FROM cp_name n WHERE %s),
    obn AS (SELECT n.* FROM cp_name n WHERE n.variant_class = 'observed'),
    own AS (  -- observed names with an address of their own
      SELECT n.ein, n.name_key, a.street_key, a.zip5, a.link_key, a.observed
      FROM obn n JOIN cp_addr a ON a.ein = n.ein AND a.observed AND a.link_key = n.name_key
    )
    SELECT n.ein, n.name_key, n.variant_class, f.street_key, f.zip5, f.link_key, f.observed
      FROM fpn n LEFT JOIN fp f USING (ein)
    UNION ALL
    SELECT o.ein, o.name_key, 'observed', o.street_key, o.zip5, o.link_key, o.observed FROM own o
    UNION ALL
    SELECT n.ein, n.name_key, 'observed', f.street_key, f.zip5, f.link_key, f.observed
      FROM obn n LEFT JOIN fp f USING (ein)
      WHERE NOT EXISTS (SELECT 1 FROM own o WHERE o.ein = n.ein AND o.name_key = n.name_key)",
    first_party_names))

  shape <- q("SELECT p.variant_class AS name_class,
                     coalesce(a.address_class, '(none)') AS address_class,
                     count(*) AS rows, count(DISTINCT p.ein) AS eins
              FROM cp_pair p LEFT JOIN cp_addr a USING (ein, street_key, zip5, link_key, observed)
              GROUP BY 1, 2 ORDER BY 3 DESC")
  n_rows <- sum(shape$rows)
  if (n_rows > max_rows) {
    by_class <- stats::aggregate(rows ~ name_class, shape, sum)
    by_class <- by_class[order(-by_class$rows), ]
    stop(sprintf("spec %s would emit %s rows, over max_rows = %s. Rows by name class: %s",
                 spec$spec_hash, format(n_rows, big.mark = ","), format(max_rows, big.mark = ","),
                 paste(sprintf("%s %s", by_class$name_class,
                               format(by_class$rows, big.mark = ",")), collapse = "; ")),
         call. = FALSE)
  }
  msg("spec %s: %s rows over %s EINs", spec$spec_hash, format(n_rows, big.mark = ","),
      format(q("SELECT count(DISTINCT ein) AS n FROM cp_pair")$n, big.mark = ","))

  # With derive = "stored", each row takes its derived columns from a stored
  # row holding exactly its strings: the name row with this spelling, the
  # address row with this street, zip and state, the DBA row with this DBA.
  stored <- derive == "stored"
  sel <- function(prefix, cols) if (!stored) "" else
    paste0(", ", paste(sprintf("%s.%s AS \"%s%s\"", prefix, cols,
                               if (prefix == "ad") ".a_" else "", cols), collapse = ", "))
  ref <- q(sprintf("
    SELECT p.ein AS \".ein\", n.name_raw AS name,
           CASE WHEN p.variant_class = 'legal' THEN coalesce(d.dba, '') ELSE '' END AS dba,
           '' AS division,
           coalesce(a.street_raw, '') AS street, coalesce(a.unit_raw, '') AS unit,
           coalesce(a.city_raw, '') AS city, coalesce(a.county, '') AS county,
           coalesce(a.state, '') AS state, coalesce(p.zip5, '') AS zip5,
           coalesce(a.zip_plus4, '') AS zip_plus4, e.active,
           p.variant_class, coalesce(a.address_class, '') AS address_class, e.layer,
           CASE WHEN p.variant_class = 'legal' THEN d.dba_key END AS \".dba_key\",
           a.address_id IS NOT NULL AS \".has_address\" %s %s
    FROM cp_pair p
    JOIN cp_name n ON n.ein = p.ein AND n.name_key = p.name_key
    JOIN cp_ein e ON e.ein = p.ein
    LEFT JOIN cp_addr a ON a.ein = p.ein AND a.street_key = p.street_key AND a.zip5 = p.zip5
                       AND a.link_key = p.link_key AND a.observed = p.observed
    LEFT JOIN cp_dba d ON d.ein = p.ein
    %s
    ORDER BY p.ein, n.variant_class, n.class_rank, p.street_key NULLS LAST, p.zip5, p.link_key",
    sel("nd", .md_derived_name_cols), sel("ad", .md_address_cols()),
    if (!stored) "" else
      "LEFT JOIN name_derived nd ON nd.name_id = n.name_id
       LEFT JOIN address_derived ad ON ad.address_id = a.address_id"))
  ref <- cbind(.id = seq_len(nrow(ref)), ref)
  # the hygiene np_reference() applies to every text field, so a frame from
  # md_compile() and one from np_reference() agree on the same strings
  for (col in c(".ein", "name", "dba", "division", "street", "unit", "city", "county",
                "state", "zip5", "zip_plus4")) {
    ref[[col]] <- stringr::str_squish(as.character(ref[[col]]))
  }
  if (derive == "normalize") {
    ref <- npmatch::np_normalize(ref[, setdiff(names(ref), c(".dba_key", ".has_address"))])
  } else if (stored) {
    raw_zip5 <- ref$zip5
    ref <- .md_assemble_stored(ref)
    .md_check_stored(ref, raw_zip5, check_rows)
  } else {
    ref <- ref[, setdiff(names(ref), c(".dba_key", ".has_address"))]
  }

  ## ---- statistics ----------------------------------------------------------------
  st <- .md_compile_name_stats(con, spec)
  fs <- if (derive != "none") .md_frame_stats(con, nrow(ref)) else NULL
  class(ref) <- c("np_reference", "data.frame")
  out <- list(reference = ref,
              name_freq = if (derive != "none") fs$name_freq else NULL,
              token_idf = if (derive != "none") fs$token_idf else NULL,
              name_eins = st$name_eins, token_df = st$token_df, n_name_rows = st$n_name_rows)

  ## ---- report ----------------------------------------------------------------------
  per_ein <- q("SELECT n, count(*) AS eins FROM (SELECT ein, count(*) AS n FROM cp_pair GROUP BY 1)
                GROUP BY 1 ORDER BY 1")
  out$report <- list(
    spec_hash = spec$spec_hash, rows = n_rows,
    eins_selected = q("SELECT count(*) AS n FROM cp_ein")$n,
    eins_emitted = q("SELECT count(DISTINCT ein) AS n FROM cp_pair")$n,
    eins_without_address = q("SELECT count(DISTINCT ein) AS n FROM cp_pair WHERE street_key IS NULL")$n,
    shape = shape, rows_per_ein = per_ein, stats_method = st$method,
    absence = .md_compile_absence(con))
  out$spec <- spec
  out$stamp <- stamp
  for (t in c("cp_ein", "cp_name", "cp_dba", "cp_addr_raw", "cp_addr", "cp_pair")) {
    x(sprintf("DROP TABLE IF EXISTS %s", t))
  }
  structure(out, class = "md_reference")
}

#' @export
print.md_reference <- function(x, ...) {
  r <- x$report
  cat(sprintf("<md_reference %s> %s rows over %s EINs (%s selected)\n", r$spec_hash,
              format(r$rows, big.mark = ","), format(r$eins_emitted, big.mark = ","),
              format(r$eins_selected, big.mark = ",")))
  cat(sprintf("  normalizer %s; statistics %s\n", x$stamp$normalize_signature, r$stats_method))
  cat("  rows by name class x address class:\n")
  print(utils::head(r$shape, 12), row.names = FALSE)
  if (is.null(r$absence)) {
    cat("  absence: no cluster tables, so what this spec leaves out cannot be measured\n")
  } else {
    cat("  absence - selected EINs with a family member outside the selection:\n")
    print(r$absence, row.names = FALSE)
  }
  invisible(x)
}

# Statistics over names, one per (ein, name_key): summed from cells when the
# spec is a union of cells, computed directly from cp_name otherwise.
.md_compile_name_stats <- function(con, spec) {
  q <- function(sql) DBI::dbGetQuery(con, sql)
  lit <- function(v) paste0("'", gsub("'", "''", v), "'", collapse = ", ")
  cells <- is.null(spec$max_names) && is.null(spec$drop_before_year) &&
    is.null(spec$sources) &&
    all(c("stat_cell", "stat_name_cell", "stat_token_cell") %in% DBI::dbListTables(con))
  if (cells) {
    where <- sprintf("layer IN (%s) AND variant_class IN (%s) AND band IN (%s)",
                     lit(spec$layers), lit(spec$names),
                     lit(.md_bands_for(spec$min_corroborators)))
    ne <- q(sprintf("SELECT name_key, sum(n_eins) AS n FROM stat_name_cell WHERE %s GROUP BY 1", where))
    td <- q(sprintf("SELECT token, sum(n_rows) AS n FROM stat_token_cell WHERE %s GROUP BY 1", where))
    nr <- q(sprintf("SELECT coalesce(sum(n_rows), 0) AS n FROM stat_cell WHERE %s", where))$n
    method <- "summed from cells"
  } else {
    duckdb::duckdb_register(con, "cp_stop",
                            data.frame(word = toupper(npmatch::np_stopwords())))
    on.exit(duckdb::duckdb_unregister(con, "cp_stop"), add = TRUE)
    ne <- q("SELECT upper(name_key) AS name_key, count(*) AS n FROM cp_name GROUP BY 1")
    td <- q("SELECT token, count(*) AS n FROM (
               SELECT DISTINCT ein, name_key, unnest(string_split(upper(name_key), ' ')) AS token
               FROM cp_name)
             WHERE length(token) >= 2 AND token NOT IN (SELECT word FROM cp_stop) GROUP BY 1")
    nr <- q("SELECT count(*) AS n FROM cp_name")$n
    method <- if (cells) "summed from cells" else
      "computed directly (the spec cuts across cells, or stat tables are missing)"
  }
  list(name_eins = stats::setNames(as.integer(ne$n), ne$name_key),
       token_df = stats::setNames(as.integer(td$n), td$token),
       n_name_rows = as.numeric(nr), method = method)
}

# For each cluster type: selected EINs with at least one family member outside
# the selection, and how many such outside EINs there are, by their layer.
.md_compile_absence <- function(con) {
  if (!all(c("cluster", "cluster_member") %in% DBI::dbListTables(con))) return(NULL)
  DBI::dbGetQuery(con, "
    WITH touch AS (
      SELECT DISTINCT m.cluster_id FROM cluster_member m JOIN cp_ein s USING (ein)
    ), mem AS (
      SELECT c.cluster_type, m.cluster_id, m.ein, s.ein IS NOT NULL AS inside
      FROM cluster_member m JOIN touch USING (cluster_id)
      JOIN cluster c USING (cluster_id) LEFT JOIN cp_ein s USING (ein)
    ), mixed AS (
      SELECT cluster_id FROM mem GROUP BY 1 HAVING bool_or(inside) AND bool_or(NOT inside)
    )
    SELECT m.cluster_type,
           count(DISTINCT m.ein) FILTER (WHERE m.inside) AS selected_eins_with_outside_family,
           count(DISTINCT m.ein) FILTER (WHERE NOT m.inside) AS outside_family_eins,
           count(DISTINCT m.cluster_id) AS clusters_split
    FROM mem m JOIN mixed USING (cluster_id)
    GROUP BY 1 ORDER BY 2 DESC")
}

# What a compiled reference was built from: the spec, the database's loaded
# sources, and the normalizer - which must be the one that built name_derived.
.md_compile_stamp <- function(con, spec) {
  sig <- npmatch::np_normalize_signature()
  stored <- DBI::dbGetQuery(con, "SELECT DISTINCT normalize_signature AS s FROM name_derived")$s
  if (length(stored) != 1L || !identical(stored, sig)) {
    stop("installed normalizer ", sig, " does not match the one that built name_derived (",
         paste(stored, collapse = ", "), "). Rebuild the derived tables, or install the ",
         "npmatch that built them.", call. = FALSE)
  }
  sv <- DBI::dbGetQuery(con, "
    SELECT vintage_id, coalesce(local_md5, '') AS m, row_count FROM source_vintage ORDER BY 1")
  list(spec_hash = spec$spec_hash,
       db_fingerprint = substr(.md_md5_string(paste(sv$vintage_id, sv$m, sv$row_count,
                                                     collapse = "\n")), 1, 16),
       normalize_signature = sig,
       npmatch_version = as.character(utils::packageVersion("npmatch")),
       matchdb_version = as.character(utils::packageVersion("matchdb")),
       built = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))
}

# The columns md_compile() hands to np_normalize(), in order.
.md_frame_inputs <- c(".id", ".ein", "name", "dba", "division", "street", "unit", "city",
                      "county", "state", "zip5", "zip_plus4", "active", "variant_class",
                      "address_class", "layer")

# np_normalize() of an all-blank row: the derived values for a row with no
# address, no dba and no division, and the column order and types of a frame.
.md_blank_frame <- function() {
  b <- data.frame(.id = 1L, .ein = "", name = "", dba = "", division = "", street = "",
                  unit = "", city = "", county = "", state = "", zip5 = "", zip_plus4 = "",
                  active = NA, variant_class = "", address_class = "", layer = "",
                  stringsAsFactors = FALSE)
  npmatch::np_normalize(b)
}

# Turn a compiled frame carrying stored derived columns into the frame
# np_normalize() would have produced from its raw columns.
.md_assemble_stored <- function(ref) {
  proto <- .md_blank_frame()
  has <- ref$.has_address %in% TRUE
  for (col in .md_address_cols()) {
    v <- ref[[paste0(".a_", col)]]
    v[!has] <- proto[[col]]
    ref[[col]] <- v                    # zip5 here is np_normalize()'s parsed zip5
  }
  ref$dba_key <- ifelse(ref$dba == "", proto$dba_key, ref$.dba_key)
  ref$division_key <- proto$division_key
  for (col in names(proto)) {
    if (!col %in% names(ref)) stop("stored frame lacks ", col, call. = FALSE)
    ref[[col]] <- methods::as(ref[[col]], class(proto[[col]])[1])
  }
  ref <- ref[, names(proto)]
  rownames(ref) <- NULL
  ref
}

# Compare a sample of a stored-column frame with np_normalize() of the same
# rows' raw columns. Any difference is an error naming the columns: stored
# values that disagree with the installed normalizer must never pass silently.
.md_check_stored <- function(ref, raw_zip5, n = 2000L) {
  if (!nrow(ref) || n <= 0L) return(invisible(0L))
  idx <- unique(round(seq(1, nrow(ref), length.out = min(n, nrow(ref)))))
  raw <- ref[idx, .md_frame_inputs]
  raw$zip5 <- raw_zip5[idx]
  fresh <- npmatch::np_normalize(raw)
  derived <- setdiff(names(fresh), setdiff(.md_frame_inputs, "zip5"))
  same <- function(a, b) identical(ifelse(is.na(a), "<NA>", as.character(a)),
                                   ifelse(is.na(b), "<NA>", as.character(b)))
  bad <- derived[!vapply(derived, function(c) same(ref[[c]][idx], fresh[[c]]), logical(1))]
  if (length(bad)) {
    c1 <- bad[1]; i <- which(ifelse(is.na(ref[[c1]][idx]), "<NA>", as.character(ref[[c1]][idx])) !=
                             ifelse(is.na(fresh[[c1]]), "<NA>", as.character(fresh[[c1]])))[1]
    stop(sprintf("stored derived columns disagree with np_normalize() on %s (of %d sampled rows). First: %s row %d: stored '%s', normalize '%s'. Rebuild with md_build_derived().",
                 paste(bad, collapse = ", "), length(idx), c1, idx[i],
                 ref[[c1]][idx[i]], fresh[[c1]][i]), call. = FALSE)
  }
  invisible(length(idx))
}

# npmatch's np_name_freq() and np_token_idf() over the emitted frame, computed
# in DuckDB from cp_pair rather than in R from the frame - 90 of 133 seconds
# for a 2.6M-row compile. Same definitions exactly: keys uppercased; tokens split
# on whitespace, counted once per row, at least two characters, not in
# np_stopwords(); idf = log(N / df) with N the frame's rows. The same values
# as npmatch's, as a named lookup; only the order of the names differs.
.md_frame_stats <- function(con, n_rows) {
  duckdb::duckdb_register(con, "cp_fstop", data.frame(word = npmatch::np_stopwords()))
  on.exit(duckdb::duckdb_unregister(con, "cp_fstop"), add = TRUE)
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cp_fkeys AS
    SELECT row_number() OVER () AS r, upper(coalesce(name_key, '')) AS k FROM cp_pair")
  nf <- DBI::dbGetQuery(con, "SELECT k, count(*) AS n FROM cp_fkeys GROUP BY 1")
  df <- DBI::dbGetQuery(con, "
    SELECT t, count(*) AS n FROM (
      SELECT DISTINCT r, unnest(regexp_split_to_array(k, '\\s+')) AS t FROM cp_fkeys)
    WHERE length(t) >= 2 AND t NOT IN (SELECT word FROM cp_fstop) GROUP BY 1")
  DBI::dbExecute(con, "DROP TABLE cp_fkeys")
  # sorted in C order: npmatch looks these up by name, so order carries nothing,
  # and the locale-collated order table() gives cost 41 s on 2.2M keys
  nf <- nf[order(nf$k, method = "radix"), ]; df <- df[order(df$t, method = "radix"), ]
  list(name_freq = stats::setNames(as.integer(nf$n), nf$k),
       token_idf = stats::setNames(log(n_rows / as.numeric(df$n)), df$t))
}
