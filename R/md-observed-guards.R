#' Guards on observed names: is the written name really this EIN's?
#'
#' Schedule I and Schedule R give a *(name, EIN)* pair written by a third party.
#' Both halves can be wrong, and wrong in systematic ways that corroboration does
#' not screen out, because the same habit repeats across filers. networked990's
#' resolver checks every written EIN against its names (`R/resolve.R` v1.4-v1.6)
#' and in one rebuild dropped 18,326 own or group-central EINs, found 39,016
#' written EINs whose names share no word with the mention, and 2,879 EINs
#' written for many unrelated names (fiscal sponsors). Loaded unchecked, every one
#' of those becomes an alias here.
#'
#' `md_guard_observed()` flags `observed` rows rather than dropping them, so the
#' raw observation keeps its provenance and the choice stays with the spec.
#'
#' @section Columns written on `name`:
#' \describe{
#'   \item{`flag_placeholder_ein`}{EIN is a placeholder: nine repeated digits,
#'     `123456789`, `987654321`, or a value below 1,000,000 (`EIN-00-0xxxxxx`;
#'     the ingests zero-pad, so a written `0` lands here).}
#'   \item{`flag_placeholder_name`}{Name is no name by npmatch's rule,
#'     [npmatch::np_name_placeholder()]: `SEE SCHEDULE O`,
#'     `SEE ATTACHED`, `VARIOUS`, `N/A`, `NONE`, `SAME AS ABOVE`, blank, or no
#'     letters - unless it is consistent with the EIN's own names
#'     (`SEE` for Social and Environmental Entrepreneurs).}
#'   \item{`flag_own_ein`}{The only filers who wrote this name for this EIN
#'     were the EIN itself, and the name is not consistent with that EIN's names
#'     (a grantee or related organisation listed under the filer's EIN). A name
#'     other filers also wrote for the EIN is not flagged: on Schedule R that is
#'     an affiliate listing itself under a name its siblings use too.}
#'   \item{`flag_group_central`}{EIN is a group-ruling central (BMF affiliation
#'     code 6 or 8) and the name shares no word with the central's names other
#'     than denomination words (a congregation written under the PC(USA) EIN).}
#'   \item{`flag_multi_name`}{EIN was written on others' Schedule I for
#'     `sponsor_min_names`+ names inconsistent with its own, by
#'     `sponsor_min_filers`+ filers, and this row is one of those names (a project
#'     under Tides Center or Fractured Atlas). The EIN's consistent names keep no
#'     flag. `entity.multi_name_ein` marks the EIN itself. Not only fiscal
#'     sponsors meet this: universities (departments, centres), denominational
#'     centrals and national federations do too, and their rows are flagged
#'     alike - a name unlike the EIN's own is not an alias of it either way.
#'     Applies to Schedule R rows on the same EIN as well.}
#'   \item{`name_ein_consistent`}{The name shares a distinctive word (3+
#'     characters, on no more than `common_min_eins` EINs' names) or any two
#'     words of 3+ characters with one of the EIN's first-party names, equals one
#'     (spaces ignored), or is its acronym, long prefix or abbreviation.
#'     Apostrophes are dropped before keying (`ST MARY'S` = `ST MARYS`). `NA`
#'     when the EIN has no first-party name to
#'     compare against. Not a guard by itself: it also fails for real brand
#'     names, and for subordinates whose BMF name is the parent's.}
#'   \item{`guard_any`}{Any of the five `flag_*` columns. The spec filter that
#'     matches networked990's resolver is `NOT guard_any`.}
#' }
#'
#' First-party names are `legal`, `dba`, `division` and `former` rows from any
#' source (BMF, return headers, 1023-EZ). Re-run this after every ingest that
#' adds them: flags computed before the return headers load see fewer names.
#'
#' The name key, abbreviations, stop words and placeholder rule are npmatch's
#' ([npmatch::np_name_rules()]). `DENOM_WORDS` and the abbreviation-match rules
#' (`md_name_pair_hit()`) are copied from networked990 `R/names.R` (2026-10-21).
#'
#' @param con A connection from [md_db()].
#' @param sources `name.source` values to check. `NULL` checks every `observed`
#'   row.
#' @param common_min_eins A word on more than this many EINs' first-party names
#'   is too common to show two names are the same organisation.
#' @param sponsor_min_names,sponsor_min_filers Fiscal-sponsor thresholds.
#' @return Per-flag row counts by source, invisibly.
#' @export
md_guard_observed <- function(con, sources = NULL, common_min_eins = 2000L,
                              sponsor_min_names = 5L, sponsor_min_filers = 2L) {
  msg <- function(...) message(sprintf(...))
  .md_name_guard_columns(con)
  .md_guard_macros(con)
  src_sql <- if (is.null(sources)) "TRUE" else
    sprintf("source IN (%s)", paste(sprintf("'%s'", sources), collapse = ", "))

  # observed rows to check, keyed
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE g_obs AS
    SELECT name_id, ein, source, name_raw, md_guard_key(name_raw) AS k,
           coalesce(n_self_filers, 0) AS n_self_filers, n_corroborators, filer_ein_lo, filer_ein_hi
    FROM name WHERE variant_class = 'observed' AND %s", src_sql))
  # first-party names of those EINs
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE g_fp AS
    SELECT DISTINCT ein, md_guard_key(name_raw) AS k FROM name
    WHERE variant_class IN ('legal', 'dba', 'division', 'former')
      AND ein IN (SELECT DISTINCT ein FROM g_obs)")
  DBI::dbExecute(con, "DELETE FROM g_fp WHERE k = ''")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE g_common AS
    SELECT w FROM (
      SELECT DISTINCT ein, unnest(string_split(md_guard_key(name_raw), ' ')) AS w
      FROM name WHERE variant_class IN ('legal', 'dba', 'division', 'former'))
    WHERE w <> '' GROUP BY 1 HAVING count(*) > %d", as.integer(common_min_eins)))

  denom_sql <- paste0("[", paste(sprintf("'%s'", .MD_DENOM_WORDS), collapse = ", "), "]")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE g_chk AS
    WITH ow AS (SELECT DISTINCT name_id, ein, unnest(string_split(k, ' ')) AS w FROM g_obs WHERE k <> ''),
         fw AS (SELECT DISTINCT ein, unnest(string_split(k, ' ')) AS w FROM g_fp),
         hit AS (SELECT ow.name_id, ow.w FROM ow JOIN fw USING (ein, w) WHERE length(ow.w) >= 3),
         share AS (SELECT DISTINCT name_id FROM hit WHERE w NOT IN (SELECT w FROM g_common)),
         -- two shared words, common or not: AMERICAN RED CROSS / AMERICAN NATIONAL
         -- RED CROSS, whose every word is common because of its own chapters
         share2 AS (SELECT name_id FROM hit GROUP BY 1 HAVING count(DISTINCT w) >= 2),
         share_nd AS (SELECT DISTINCT name_id FROM hit WHERE NOT list_contains(%s, w)),
         -- equal keys, or equal once spaces are dropped (LA FONTAINE / LAFONTAINE)
         exact AS (SELECT DISTINCT o.name_id FROM g_obs o JOIN g_fp f
                   ON f.ein = o.ein AND replace(f.k, ' ', '') = replace(o.k, ' ', '')),
         has_fp AS (SELECT DISTINCT ein FROM g_fp)
    SELECT o.*, o.ein IN (SELECT ein FROM has_fp) AS has_fp,
           o.name_id IN (SELECT name_id FROM exact) AS exact,
           o.name_id IN (SELECT name_id FROM share) OR o.name_id IN (SELECT name_id FROM share2) AS word_shared,
           o.name_id IN (SELECT name_id FROM share_nd) AS nondenom_shared,
           coalesce(e.affiliation_code IN ('6', '8'), false) AS central,
           FALSE AS abbrev
    FROM g_obs o LEFT JOIN entity e USING (ein)", denom_sql))

  # acronym, long-prefix and abbreviation rules, in R on the rows still failing
  pr <- DBI::dbGetQuery(con, "
    SELECT c.name_id, c.k AS qk, f.k AS nk FROM g_chk c JOIN g_fp f USING (ein)
    WHERE c.k <> '' AND NOT c.exact AND (NOT c.word_shared OR (c.central AND NOT c.nondenom_shared))")
  if (nrow(pr)) {
    hit <- md_name_pair_hit(pr$qk, pr$nk) | md_name_pair_hit(pr$nk, pr$qk)
    ab <- data.frame(name_id = unique(pr$name_id[hit]))
    if (nrow(ab)) {
      duckdb::duckdb_register(con, "g_ab", ab)
      DBI::dbExecute(con, "UPDATE g_chk SET abbrev = TRUE WHERE name_id IN (SELECT name_id FROM g_ab)")
      duckdb::duckdb_unregister(con, "g_ab")
    }
  }

  # placeholder names: npmatch's rule, the one npmatch applies when matching,
  # evaluated in R on the distinct strings (its cleaning step has no SQL twin)
  ph <- DBI::dbGetQuery(con, "SELECT DISTINCT name_raw FROM g_obs")
  ph$ph <- npmatch::np_name_placeholder(ph$name_raw)
  ph <- ph[ph$ph, "name_raw", drop = FALSE]
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE g_ph (name_raw VARCHAR)")
  if (nrow(ph)) DBI::dbAppendTable(con, "g_ph", ph)

  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE g_flag AS
    SELECT name_id, ein, source, n_self_filers, n_corroborators, filer_ein_lo, filer_ein_hi, k,
           coalesce(md_placeholder_ein(ein), false) AS flag_placeholder_ein,
           -- a name consistent with the EIN's own is a name: SEE for
           -- Social and Environmental Entrepreneurs
           name_raw IN (SELECT name_raw FROM g_ph)
             AND NOT (has_fp AND k <> '' AND (exact OR word_shared OR abbrev))
             AS flag_placeholder_name,
           CASE WHEN k = '' THEN NULL
                WHEN NOT has_fp THEN NULL
                ELSE exact OR word_shared OR abbrev END AS name_ein_consistent,
           central AND has_fp AND k <> '' AND NOT exact AND NOT nondenom_shared AND NOT abbrev
             AS flag_group_central
    FROM g_chk")
  DBI::dbExecute(con, "ALTER TABLE g_flag ADD COLUMN flag_own_ein BOOLEAN")
  # Only when no other filer wrote this name for this EIN: on Schedule R an
  # affiliate often lists itself, under a name 200 of its siblings also write
  # for it (a rename the first-party names have not caught up with).
  DBI::dbExecute(con, "
    UPDATE g_flag SET flag_own_ein = n_self_filers > 0 AND n_self_filers >= coalesce(n_corroborators, 0)
                                     AND name_ein_consistent IS NOT DISTINCT FROM FALSE")

  # fiscal sponsors: written on others' Schedule I for many inconsistent names by
  # several filers. filer_ein_lo/hi exclude the EIN's own filings, so two
  # distinct filers exist exactly when the lowest and highest differ.
  if (as.integer(sponsor_min_filers) > 2L) {
    warning("sponsor_min_filers > 2 is counted as 2: rows store a filer range, not a filer set",
            call. = FALSE)
  }
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE g_sponsor AS
    SELECT ein, count(DISTINCT k) AS n_other_names,
           min(filer_ein_lo) AS lo, max(filer_ein_hi) AS hi
    FROM g_flag
    WHERE source = 'schedi' AND name_ein_consistent = FALSE AND filer_ein_lo IS NOT NULL
      AND NOT flag_placeholder_name
    GROUP BY 1
    HAVING count(DISTINCT k) >= %d AND (%d <= 1 OR min(filer_ein_lo) <> max(filer_ein_hi))",
    as.integer(sponsor_min_names), as.integer(sponsor_min_filers)))
  DBI::dbExecute(con, "ALTER TABLE g_flag ADD COLUMN flag_multi_name BOOLEAN")
  DBI::dbExecute(con, "
    UPDATE g_flag SET flag_multi_name = ein IN (SELECT ein FROM g_sponsor)
                                            AND name_ein_consistent IS NOT DISTINCT FROM FALSE")

  DBI::dbExecute(con, "
    UPDATE name SET
      flag_placeholder_ein  = g.flag_placeholder_ein,
      flag_placeholder_name = g.flag_placeholder_name,
      flag_own_ein          = g.flag_own_ein,
      flag_group_central    = g.flag_group_central,
      flag_multi_name   = g.flag_multi_name,
      name_ein_consistent   = g.name_ein_consistent,
      guard_any = g.flag_placeholder_ein OR g.flag_placeholder_name OR g.flag_own_ein
                  OR g.flag_group_central OR g.flag_multi_name
    FROM g_flag g WHERE name.name_id = g.name_id")

  if (DBI::dbExistsTable(con, "entity")) {
    DBI::dbExecute(con, "ALTER TABLE entity ADD COLUMN IF NOT EXISTS multi_name_ein BOOLEAN")
    DBI::dbExecute(con, "UPDATE entity SET multi_name_ein = ein IN (SELECT ein FROM g_sponsor)")
  }

  counts <- DBI::dbGetQuery(con, "
    SELECT source, count(*) AS n_rows,
           count(*) FILTER (WHERE flag_placeholder_ein)  AS placeholder_ein,
           count(*) FILTER (WHERE flag_placeholder_name) AS placeholder_name,
           count(*) FILTER (WHERE flag_own_ein)          AS own_ein,
           count(*) FILTER (WHERE flag_group_central)    AS group_central,
           count(*) FILTER (WHERE flag_multi_name)   AS multi_name,
           count(*) FILTER (WHERE name_ein_consistent = FALSE) AS inconsistent,
           count(*) FILTER (WHERE name_ein_consistent IS NULL) AS no_comparison,
           count(*) FILTER (WHERE flag_placeholder_ein OR flag_placeholder_name OR flag_own_ein
                            OR flag_group_central OR flag_multi_name) AS guard_any
    FROM g_flag GROUP BY 1 ORDER BY 1")
  for (i in seq_len(nrow(counts))) {
    with(counts[i, ], msg(
      "  guards %-8s %s rows: placeholder EIN %s, placeholder name %s, own EIN %s, group central %s, multi-name %s (any %s); name inconsistent %s, no names to compare %s",
      source, .md_fmt(n_rows), .md_fmt(placeholder_ein), .md_fmt(placeholder_name), .md_fmt(own_ein),
      .md_fmt(group_central), .md_fmt(multi_name), .md_fmt(guard_any), .md_fmt(inconsistent),
      .md_fmt(no_comparison)))
  }
  msg("  %s multi-name (fiscal-sponsor) EINs", .md_fmt(.md_n(con, "g_sponsor")))
  for (tb in c("g_obs", "g_fp", "g_common", "g_chk", "g_ph", "g_flag", "g_sponsor")) {
    DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s", tb))
  }
  invisible(counts)
}

.md_fmt <- function(x) format(x, big.mark = ",", scientific = FALSE)

# Columns the guards and the third-party ingests write on `name`. The BMF ingest
# creates `name` without first_year/last_year, which every later ingest inserts
# into, so those are ensured here too.
.md_name_guard_columns <- function(con) {
  cols <- c(first_year = "INTEGER", last_year = "INTEGER",
            n_self_filers = "INTEGER", filer_ein_lo = "VARCHAR", filer_ein_hi = "VARCHAR",
            flag_placeholder_ein = "BOOLEAN", flag_placeholder_name = "BOOLEAN",
            flag_own_ein = "BOOLEAN", flag_group_central = "BOOLEAN",
            flag_multi_name = "BOOLEAN", name_ein_consistent = "BOOLEAN",
            guard_any = "BOOLEAN")
  for (nm in names(cols)) {
    DBI::dbExecute(con, sprintf("ALTER TABLE name ADD COLUMN IF NOT EXISTS %s %s", nm, cols[[nm]]))
  }
  invisible(TRUE)
}

## ---- word lists -----------------------------------------------------------------
# The key and its abbreviation and stop lists are npmatch's (np_name_core(),
# np_name_rules()), the same key networked990 now uses. Denomination words are
# matchdb's own copy of networked990's DENOM_WORDS (R/names.R, 2026-10-21):
# npmatch has no such list.

.MD_DENOM_WORDS <-c("PRESBYTERIAN", "PRESBYTERY", "CHURCH", "CHURCHES", "USA", "AMERICA", "AMERICAN", "UNITED", "STATES", "METHODIST",
                     "CATHOLIC", "ROMAN", "BAPTIST", "BAPTISTS", "CONVENTION", "LUTHERAN", "EVANGELICAL", "EPISCOPAL", "PROTESTANT", "SYNOD",
                     "DIOCESE", "ARCHDIOCESE", "DIOCESAN", "CONFERENCE", "GENERAL", "ASSEMBLY", "ASSEMBLIES", "COUNCIL", "REFORMED",
                     "CHRISTIAN", "CHRIST", "GOD", "NAZARENE", "ADVENTIST", "SEVENTH", "DAY", "ORTHODOX", "BRETHREN", "MENNONITE",
                     "DISCIPLES", "CONGREGATIONAL", "CONGREGATION", "FELLOWSHIP", "MINISTRIES", "MINISTRY", "MISSION", "MISSIONS",
                     "MISSIONARY", "NATIONAL", "SOUTHERN", "NORTHERN", "NORTH", "SOUTH", "BISHOPS", "BISHOP", "PARISH", "PARENT", "GEN",
                     "CENTRAL", "ORGANIZATION", "OFFICE", "BOARD", "WORLD", "GLOBAL", "INTERNATIONAL")
.MD_PLACEHOLDER_EINS <-c(sprintf("%s", strrep(0:9, 9)), "123456789", "987654321")

#' Placeholder EINs
#'
#' The R version of the rule [md_guard_observed()] applies in SQL. Placeholder
#' *names* are npmatch's rule, [npmatch::np_name_placeholder()].
#' @param x EINs in any format.
#' @return Logical; `NA` for EINs that are not nine digits.
#' @examples
#' md_placeholder_ein(c("000000000", "12-3456789", "EIN-00-0019818", "EIN-53-0196605"))
#' @export
md_placeholder_ein <- function(x) {
  d <- suppressWarnings(md_ein(x, to = "n"))
  ifelse(is.na(d), NA, d %in% .MD_PLACEHOLDER_EINS | as.numeric(d) < 1e6)
}

#' Name key used by the guards
#'
#' npmatch's exact-lookup key, [npmatch::np_name_core()]: upper case, accents
#' removed, `&` to `AND`, apostrophes and initialism periods deleted
#' (`ST MARY'S` = `SAINT MARYS`), other punctuation to spaces, abbreviations
#' expanded, then connector words and legal forms dropped.
#' @param x Names.
#' @return Character keys, `""` for `NA`.
#' @export
md_guard_key <- function(x) {
  k <- npmatch::np_name_core(x)
  k[is.na(k)] <- ""
  k
}

# SQL counterparts, generated from npmatch::np_name_rules(). md_guard_key(s)
# must equal npmatch::np_name_core() (tested). The cleaning steps mirror
# networked990's g_name_clean(), its tested port of npmatch's: the period rule
# runs twice because each pass removes every other period of F.I.N.D.
.md_guard_macros <- function(con) {
  q <- function(x) gsub("'", "''", x)
  rules <- npmatch::np_name_rules()
  stop_sql <- paste0("[", paste(sprintf("'%s'", q(rules$core_stop)), collapse = ", "), "]")
  abbr_sql <- paste(sprintf("WHEN '%s' THEN '%s'", q(names(rules$abbrev)), q(rules$abbrev)),
                    collapse = " ")
  apos_sql <- q("['\u2018\u2019\u02bc\u00b4`]")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP MACRO md_guard_clean(s) AS trim(regexp_replace(
      regexp_replace(regexp_replace(
        regexp_replace(replace(strip_accents(upper(COALESCE(CAST(s AS VARCHAR), ''))), '&', ' AND '), '%s', '', 'g'),
        '([A-Z0-9])\\.([A-Z0-9])', '\\1\\2', 'g'), '([A-Z0-9])\\.([A-Z0-9])', '\\1\\2', 'g'),
      '[^A-Z0-9]+', ' ', 'g'))", apos_sql))
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP MACRO md_guard_key(s) AS COALESCE(array_to_string(
      list_filter(
        list_transform(list_filter(string_split(md_guard_clean(s), ' '), t -> t <> ''),
                       t -> CASE t %s ELSE t END),
        t -> NOT list_contains(%s, t)),
      ' '), '')", abbr_sql, stop_sql))
  .md_placeholder_macro(con)
  invisible(TRUE)
}

# md_placeholder_ein(e) in SQL, the rule md_placeholder_ein() applies in R. The
# builders of derived tables (groups, keys, clusters) leave these EINs out: a
# written 0 or 123456789 is not an organisation, and joining on it links every
# filer that wrote it.
.md_placeholder_macro <- function(con) {
  ph_ein <- paste(sprintf("'%s'", .MD_PLACEHOLDER_EINS), collapse = ", ")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP MACRO md_placeholder_ein(e) AS
      regexp_replace(e, '[^0-9]', '', 'g') IN (%s)
      OR TRY_CAST(regexp_replace(e, '[^0-9]', '', 'g') AS BIGINT) < 1000000", ph_ein))
  invisible(TRUE)
}

## ---- abbreviation rules, copied from networked990 R/names.R (name_pair_hit) ----

.md_name_acr <- function(t) paste(substr(t, 1, 1), collapse = "")

# each query token is a prefix of the next name token, or the initials of the next k tokens
.md_name_seq_match <- function(ct, nt) {
  j <- 1
  for (t in ct) {
    if (j > length(nt)) return(FALSE)
    if (nchar(t) >= 2 && startsWith(nt[j], t)) { j <- j + 1; next }
    k <- nchar(t)
    if (k >= 2 && j + k - 1 <= length(nt) && .md_name_acr(nt[j:(j + k - 1)]) == t) { j <- j + k; next }
    return(FALSE)
  }
  TRUE
}

#' Do two name keys name the same organisation by an abbreviation rule?
#'
#' Long prefix (8+ characters), acronym (a 2-8 letter single token equal to the
#' other's initials), or token-abbreviation sequence. `q` and `n` are keys from
#' [md_guard_key()], pairwise.
#' @param q,n Character vectors of equal length.
#' @return Logical.
#' @export
md_name_pair_hit <- function(q, n) {
  qt <- strsplit(q, " ", fixed = TRUE); nt <- strsplit(n, " ", fixed = TRUE)
  long_prefix <- pmin(nchar(q), nchar(n)) >= 8 & (startsWith(n, q) | startsWith(q, n))
  acro <- lengths(qt) == 1 & nchar(q) >= 2 & nchar(q) <= 8 & lengths(nt) >= 2 &
          vapply(nt, .md_name_acr, "") == q
  out <- long_prefix | acro | (q == n)
  rest <- which(!out & nzchar(q) & nzchar(n))
  if (length(rest)) out[rest] <- mapply(.md_name_seq_match, qt[rest], nt[rest], USE.NAMES = FALSE)
  out
}
