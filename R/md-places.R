#' Places: how crowded an address is, and what kind of place it is
#'
#' Builds the place tables `dev/PLACES.md` describes, so the matching side knows
#' for any address how many organisations report it, in how many suites, and
#' whether it is a national office, a fiscal sponsor's mail drop, a multi-tenant
#' building or an organisation with its foundation. npmatch labels addresses the
#' same way at run time (`np_addr_freq()`, branch `fix/address-class`); these
#' tables add what it cannot see.
#'
#' @details It writes three tables:
#' \describe{
#'   \item{`place`}{One row per address that two or more EINs report as their
#'     own current address. A lookup miss means one occupant, which is about
#'     88% of addresses.}
#'   \item{`place_layer`}{`(place_key, layer, n_eins)`. Layers partition EINs,
#'     so the count for any selection of layers - active only, unified - is an
#'     exact sum, as with `ein_key_layer`.}
#'   \item{`place_unit`}{One row per suite that two or more EINs at a place
#'     share.}
#' }
#'
#' @section Who counts as an occupant:
#' An EIN occupies a place when the place is its **own current address**: an
#' `address` row of class `mailing` or `principal` (the BMF, the latest 990
#' header, the e-Postcard). A grantmaker writing a grantee's address (class
#' `observed`) is not occupancy, and an old address (`historical`) counts only
#' toward the history columns.
#'
#' @section Keys:
#' `place_key` is npmatch's address key - `street_key`, a space, `zip5`, empty
#' for a PO box - and `unit_id` its suite identifier ("STE D-2" -> `D2`), so a
#' lookup from npmatch never misses on spelling. See [md_place_key()].
#'
#' @section Columns of `place`:
#' \describe{
#'   \item{`n_eins`}{occupants}
#'   \item{`n_name_keys`, `top_name_share`}{distinct legal name keys among the
#'     occupants, and the share holding the commonest one: one name dominating
#'     is a national office, names spread is a sponsor or agent}
#'   \item{`n_units`, `max_eins_per_unit`, `n_eins_with_unit`, `unit_coverage`}{
#'     recorded suites. Coverage travels with the count: at 1,601 crowded BMF
#'     addresses no record names a suite, and "several suites" can describe
#'     the data as easily as the building}
#'   \item{`n_pmb_units`, `pmb_share`}{private-mailbox suites, and the share of
#'     occupants with a suite whose suite is a PMB}
#'   \item{`n_group_exemptions`, `share_in_largest_group`, `has_group_central`}{
#'     the IRS group rulings among the occupants: a national office its chapters
#'     file from, confirmed without reading names}
#'   \item{`n_care_of_agents`, `care_of_agent_share`, `bank_trust_share`}{occupants
#'     whose in-care-of name is an agent (bank, trust company, CPA, law firm),
#'     by the word list `care_of_network` uses}
#'   \item{`n_eins_ever`, `first_year`, `last_year`, `churn`}{every EIN that has
#'     had the place as its own address, current or historical, and the share no
#'     longer there}
#'   \item{`building_id`, `n_place_keys_in_building`}{rooftop geocodes rounded
#'     to `building_digits` decimals: one building written two ways}
#'   \item{`place_class`}{npmatch's four labels by npmatch's rule and
#'     thresholds: `federated`, `building`, `shared`, `cluster`}
#'   \item{`flag_*`, `place_flags`}{what only matchdb sees: `cmra`, `care_of`,
#'     `bank_trust`, `group_confirmed`, `agent_churn`, `military_or_gd`}
#'   \item{`class_rule`, `normalize_signature`}{the stamps}
#' }
#'
#' @param con A DuckDB connection with `address`, `address_derived` and
#'   `entity`; `name`/`name_derived` (or `name_compact`), `entity_group` and the
#'   geocode columns are used when present.
#' @param share_min,unit_coverage_min,top_share_min npmatch's class thresholds
#'   (its defaults): crowded at `share_min` occupants; a building needs two
#'   suites and `unit_coverage_min` of occupants naming one; federated at
#'   `top_share_min` of occupants under one name.
#' @param flag_share Share at which a flag's evidence counts (PMB suites,
#'   care-of agents, one group ruling, churn). To be measured on the full
#'   database (`dev/PLACES.md` section 9).
#' @param building_digits Decimal places rooftop coordinates are rounded to
#'   for a building id. 4 is about 11 m of latitude; to be measured.
#' @return Row counts, invisibly.
#' @export
md_build_places <- function(con, share_min = 10L, unit_coverage_min = 0.5,
                            top_share_min = 0.5, flag_share = 0.5, building_digits = 4L) {
  msg <- function(...) message(sprintf(...))
  .md_place_macros(con)
  afields <- DBI::dbListFields(con, "address")
  dfields <- DBI::dbListFields(con, "address_derived")
  unit_expr <- if ("street_unit_id" %in% dfields) "d.street_unit_id" else "md_unit_id(d.street_unit)"
  geo <- all(c("lat", "lon", "geocode_type") %in% afields)
  opt <- function(col, as) if (col %in% afields) sprintf("a.%s AS %s", col, as) else
    sprintf("CAST(NULL AS VARCHAR) AS %s", as)
  yr <- function(col) if (col %in% afields) sprintf(
    "TRY_CAST(regexp_extract(coalesce(CAST(a.%s AS VARCHAR), ''), '^[0-9]{4}') AS INTEGER)", col) else
    "CAST(NULL AS INTEGER)"

  # Every own address of every EIN, current or historical, keyed as npmatch keys it.
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE pl_addr AS
    SELECT a.ein, e.layer, a.variant_class IN ('mailing', 'principal') AS current,
           md_place_key(d.street_key, d.zip5) AS place_key,
           %s AS unit_id, upper(regexp_extract(coalesce(d.street_unit, ''), '^(#|[A-Za-z]+)')) AS designator,
           upper(coalesce(d.street_key, '')) AS street_key, %s, %s,
           %s AS fy, %s AS ly,
           %s
    FROM address a JOIN address_derived d ON CAST(d.address_id AS BIGINT) = a.address_id
    JOIN entity e USING (ein)
    WHERE a.variant_class IN ('mailing', 'principal', 'historical')",
    unit_expr, opt("city_raw", "city"), opt("state", "state"),
    yr("first_vintage"), yr("last_vintage"),
    if (geo) "a.lat, a.lon, a.geocode_type" else
      "CAST(NULL AS DOUBLE) AS lat, CAST(NULL AS DOUBLE) AS lon, CAST(NULL AS VARCHAR) AS geocode_type"))
  DBI::dbExecute(con, "DELETE FROM pl_addr WHERE place_key = ''")
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE pl_occ AS SELECT * FROM pl_addr WHERE current")

  # One legal name key per EIN: the BMF's where there is one, else the most recent.
  .md_place_names(con)
  # Care-of agents per EIN, by the word list care_of_network uses.
  .md_place_care_of(con)

  # Group rulings: a group exemption number of all zeros is none.
  gen <- if ("group_exemption_number" %in% DBI::dbListFields(con, "entity")) {
    "nullif(regexp_replace(coalesce(CAST(e.group_exemption_number AS VARCHAR), ''), '^0+$', ''), '')"
  } else "CAST(NULL AS VARCHAR)"
  central <- if (DBI::dbExistsTable(con, "entity_group")) {
    "o.ein IN (SELECT group_central_ein FROM entity_group)"
  } else "NULL"

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE pl_ein AS
    SELECT o.place_key, o.ein, any_value(o.layer) AS layer,
           bool_or(o.unit_id IS NOT NULL) AS has_unit,
           bool_or(o.designator = 'PMB') AS pmb,
           min(%s) AS gen, bool_or(%s) AS is_central,
           any_value(n.name_key) AS name_key,
           bool_or(coalesce(c.agent, FALSE)) AS agent, bool_or(coalesce(c.bank, FALSE)) AS bank
    FROM pl_occ o JOIN entity e USING (ein)
    LEFT JOIN pl_name n USING (ein) LEFT JOIN pl_care c USING (ein)
    GROUP BY 1, 2", gen, central))

  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE pl_unit AS
    SELECT place_key, unit_id, count(DISTINCT ein) AS n_eins,
           count(DISTINCT n.name_key) AS n_name_keys, bool_or(designator = 'PMB') AS is_pmb
    FROM pl_occ LEFT JOIN pl_name n USING (ein)
    WHERE unit_id IS NOT NULL GROUP BY 1, 2")

  # Rooftop points to a building cell; a place takes its commonest cell.
  if (geo) {
    cell <- sprintf("CAST(round(TRY_CAST(lat AS DOUBLE), %1$d) AS VARCHAR) || ',' ||
                     CAST(round(TRY_CAST(lon AS DOUBLE), %1$d) AS VARCHAR)", as.integer(building_digits))
    DBI::dbExecute(con, sprintf("
      CREATE OR REPLACE TEMP TABLE pl_bld AS
      SELECT place_key, cell FROM (
        SELECT place_key, %1$s AS cell,
               row_number() OVER (PARTITION BY place_key ORDER BY count(*) DESC, %1$s) AS rk
        FROM pl_addr WHERE geocode_type = 'PointAddress' AND lat IS NOT NULL AND lon IS NOT NULL
        GROUP BY place_key, %1$s)
      WHERE rk = 1", cell))
  } else {
    DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE pl_bld (place_key VARCHAR, cell VARCHAR)")
  }

  rule <- sprintf("npmatch-addr-class/share_min=%d,unit_coverage_min=%s,top_share_min=%s;flags/share=%s;building_digits=%d",
                  as.integer(share_min), unit_coverage_min, top_share_min, flag_share,
                  as.integer(building_digits))
  sig <- if ("normalize_signature" %in% dfields) {
    DBI::dbGetQuery(con, "SELECT min(normalize_signature) AS s FROM address_derived")$s
  } else NA_character_
  q <- function(x) DBI::dbQuoteString(con, as.character(x))

  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE place AS
    WITH base AS (
      SELECT place_key, count(*) AS n_eins,
             count(DISTINCT name_key) AS n_name_keys,
             count(*) FILTER (WHERE has_unit) AS n_eins_with_unit,
             count(*) FILTER (WHERE pmb) AS n_eins_pmb,
             count(DISTINCT gen) AS n_group_exemptions,
             bool_or(is_central) AS has_group_central,
             count(*) FILTER (WHERE agent) AS n_eins_agent,
             count(*) FILTER (WHERE bank) AS n_eins_bank
      FROM pl_ein GROUP BY 1 HAVING count(*) >= 2
    ), top_name AS (
      SELECT place_key, max(n) AS n_top FROM (
        SELECT place_key, name_key, count(*) AS n FROM pl_ein WHERE name_key IS NOT NULL
        GROUP BY 1, 2) GROUP BY 1
    ), top_group AS (
      SELECT place_key, max(n) AS n_top FROM (
        SELECT place_key, gen, count(*) AS n FROM pl_ein WHERE gen IS NOT NULL GROUP BY 1, 2)
      GROUP BY 1
    ), units AS (
      SELECT place_key, count(*) AS n_units, max(n_eins) AS max_eins_per_unit,
             count(*) FILTER (WHERE is_pmb) AS n_pmb_units
      FROM pl_unit GROUP BY 1
    ), agents AS (
      SELECT o.place_key, count(DISTINCT c.agent_key) AS n_care_of_agents
      FROM pl_occ o JOIN pl_care c USING (ein) WHERE c.agent GROUP BY 1
    ), hist AS (
      SELECT place_key, count(DISTINCT ein) AS n_eins_ever,
             min(coalesce(fy, ly)) AS first_year, max(coalesce(ly, fy)) AS last_year,
             bool_or(state IN ('AA', 'AE', 'AP') OR upper(trim(coalesce(city, ''))) IN ('APO', 'FPO', 'DPO')
                     OR regexp_matches(street_key, '^(GENERAL DELIVERY|PSC [0-9]+|CMR [0-9]+|UNIT [0-9]+ BOX)')) AS military_or_gd,
             bool_or(regexp_matches(street_key, '^C O ')) AS care_of_street,
             bool_or(regexp_matches(street_key, '(^| )[A-Z]{2}[0-9]{1,2} [0-9]{3,5}$')) AS mail_code
      FROM pl_addr GROUP BY 1
    ), bld AS (
      SELECT b.place_key, md5('bld.v1' || chr(31) || b.cell) AS building_id,
             count(*) OVER (PARTITION BY b.cell) AS n_place_keys_in_building
      FROM pl_bld b
    ), m AS (
      SELECT b.*,
             round(coalesce(t.n_top, 0)::DOUBLE / b.n_eins, 4) AS top_name_share,
             coalesce(u.n_units, 0) AS n_units, coalesce(u.max_eins_per_unit, 0) AS max_eins_per_unit,
             round(b.n_eins_with_unit::DOUBLE / b.n_eins, 4) AS unit_coverage,
             coalesce(u.n_pmb_units, 0) AS n_pmb_units,
             round(b.n_eins_pmb::DOUBLE / nullif(b.n_eins_with_unit, 0), 4) AS pmb_share,
             round(coalesce(g.n_top, 0)::DOUBLE / b.n_eins, 4) AS share_in_largest_group,
             coalesce(a.n_care_of_agents, 0) AS n_care_of_agents,
             round(b.n_eins_agent::DOUBLE / b.n_eins, 4) AS care_of_agent_share,
             round(b.n_eins_bank::DOUBLE / b.n_eins, 4) AS bank_trust_share,
             h.n_eins_ever, h.first_year, h.last_year,
             round(1 - b.n_eins::DOUBLE / greatest(h.n_eins_ever, b.n_eins), 4) AS churn,
             h.military_or_gd, h.care_of_street, h.mail_code,
             x.building_id, x.n_place_keys_in_building
      FROM base b LEFT JOIN top_name t USING (place_key) LEFT JOIN top_group g USING (place_key)
      LEFT JOIN units u USING (place_key) LEFT JOIN agents a USING (place_key)
      LEFT JOIN hist h USING (place_key) LEFT JOIN bld x USING (place_key)
    ), c AS (
      SELECT *,
        -- npmatch's .np_addr_class(): shared, then building over it, then federated over both
        CASE WHEN n_eins >= %d AND top_name_share >= %s THEN 'federated'
             WHEN n_eins >= %d AND n_units >= 2 AND unit_coverage >= %s THEN 'building'
             WHEN n_eins >= %d THEN 'shared'
             ELSE 'cluster' END AS place_class,
        coalesce(pmb_share >= %s AND n_eins_with_unit >= 2, FALSE) AS flag_cmra,
        care_of_street OR care_of_agent_share >= %s AS flag_care_of,
        mail_code OR bank_trust_share >= %s AS flag_bank_trust,
        share_in_largest_group >= %s AS flag_group_confirmed,
        n_eins_ever >= %d AND churn >= %s AS flag_agent_churn,
        military_or_gd AS flag_military_or_gd
      FROM m
    )
    SELECT place_key, n_eins, n_name_keys, top_name_share, n_units, max_eins_per_unit,
           n_eins_with_unit, unit_coverage, n_pmb_units, pmb_share, n_group_exemptions,
           share_in_largest_group, has_group_central, n_care_of_agents, care_of_agent_share,
           bank_trust_share, n_eins_ever, first_year, last_year, churn, building_id,
           n_place_keys_in_building, place_class, flag_cmra, flag_care_of, flag_bank_trust,
           flag_group_confirmed, flag_agent_churn, flag_military_or_gd,
           concat_ws(',', CASE WHEN flag_cmra THEN 'cmra' END, CASE WHEN flag_care_of THEN 'care_of' END,
                     CASE WHEN flag_bank_trust THEN 'bank_trust' END,
                     CASE WHEN flag_group_confirmed THEN 'group_confirmed' END,
                     CASE WHEN flag_agent_churn THEN 'agent_churn' END,
                     CASE WHEN flag_military_or_gd THEN 'military_or_gd' END) AS place_flags,
           %s AS class_rule, %s AS normalize_signature
    FROM c ORDER BY place_key",
    as.integer(share_min), top_share_min, as.integer(share_min), unit_coverage_min,
    as.integer(share_min), flag_share, flag_share, flag_share, flag_share,
    as.integer(share_min), flag_share, q(rule), if (is.na(sig)) "NULL" else q(sig)))

  DBI::dbExecute(con, "
    CREATE OR REPLACE TABLE place_layer AS
    SELECT e.place_key, e.layer, count(*) AS n_eins
    FROM pl_ein e WHERE e.place_key IN (SELECT place_key FROM place)
    GROUP BY 1, 2 ORDER BY 1, 2")
  DBI::dbExecute(con, "
    CREATE OR REPLACE TABLE place_unit AS
    SELECT place_key, unit_id, n_eins, n_name_keys, is_pmb FROM pl_unit
    WHERE n_eins >= 2 ORDER BY 1, 2")
  for (t in c("pl_addr", "pl_occ", "pl_name", "pl_care", "pl_ein", "pl_unit", "pl_bld")) {
    DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s", t))
  }

  out <- c(place = .md_n(con, "place"), place_layer = .md_n(con, "place_layer"),
           place_unit = .md_n(con, "place_unit"))
  cls <- DBI::dbGetQuery(con, "SELECT place_class, count(*) AS places, sum(n_eins) AS eins
                               FROM place GROUP BY 1 ORDER BY 1")
  msg("place: %s shared places (%s); place_unit: %s shared suites",
      format(out[["place"]], big.mark = ","),
      paste(sprintf("%s %s", cls$place_class, format(cls$places, big.mark = ",")), collapse = ", "),
      format(out[["place_unit"]], big.mark = ","))
  invisible(out)
}

# One legal name key per EIN, into pl_name (ein, name_key).
.md_place_names <- function(con) {
  if (DBI::dbExistsTable(con, "name") && DBI::dbExistsTable(con, "name_derived")) {
    yr <- if ("last_year" %in% DBI::dbListFields(con, "name")) "n.last_year" else "NULL"
    DBI::dbExecute(con, sprintf("
      CREATE OR REPLACE TEMP TABLE pl_name AS
      SELECT ein, name_key FROM (
        SELECT n.ein, d.name_key,
               row_number() OVER (PARTITION BY n.ein
                 ORDER BY CASE WHEN n.source = 'bmf' THEN 0 ELSE 1 END, %s DESC NULLS LAST,
                          d.name_key) AS rk
        FROM name n JOIN name_derived d ON CAST(d.name_id AS BIGINT) = n.name_id
        WHERE n.variant_class = 'legal' AND coalesce(d.name_key, '') <> '')
      WHERE rk = 1", yr))
  } else {
    DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE pl_name (ein VARCHAR, name_key VARCHAR)")
  }
}

# Care-of agents per EIN, into pl_care (ein, agent_key, agent, bank).
.md_place_care_of <- function(con) {
  if (!(DBI::dbExistsTable(con, "name") && DBI::dbExistsTable(con, "name_derived"))) {
    DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE pl_care
                         (ein VARCHAR, agent_key VARCHAR, agent BOOLEAN, bank BOOLEAN)")
    return(invisible())
  }
  words <- function(x) paste(x, collapse = "|")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE pl_care AS
    SELECT n.ein, d.name_key AS agent_key,
           regexp_matches(d.name_key, '(^| )(%s)( |$)') AS agent,
           regexp_matches(d.name_key, '(^| )(%s)( |$)') AS bank
    FROM name n JOIN name_derived d ON CAST(d.name_id AS BIGINT) = n.name_id
    WHERE n.variant_class = 'in_care_of' AND coalesce(d.name_key, '') <> ''",
    words(.md_ico_agents), words(.md_bank_agents)))
}

# The banks and trust companies among the care-of agents.
.md_bank_agents <- c("BANK", "BANCORP", "TRUST CO", "TRUST COMPANY", "NATIONAL ASSOCIATION",
  "N A", "WELLS FARGO", "JPMORGAN", "CHASE", "CITIBANK", "MELLON", "NORTHERN TRUST",
  "US BANK", "PNC", "FIDUCIARY")

#' npmatch's address key and suite identifier
#'
#' `md_place_key()` is npmatch's address key: the normalized street, a space,
#' the five-digit ZIP; empty for a PO box, because a box number is the address
#' and counting records at one counts its owners, not a building's tenants.
#' `md_unit_id()` is the suite identifier with its designator and separators
#' dropped ("STE D-2" -> `D2`, "# 300" -> `300`), so "STE 300", "Suite 300" and
#' "# 300" are one office.
#'
#' Both call npmatch's own function when the installed npmatch has it
#' (`np_addr_key()` / `np_unit_id()` if exported, else the internal versions
#' from `fix/address-class` on), and otherwise apply a port of the same rule.
#' The SQL macros `md_place_key()` and `md_unit_id()` are the port; a test
#' holds them to npmatch's functions whenever those are installed.
#'
#' @param street_key npmatch's `street_key`.
#' @param zip5 Five-digit ZIP.
#' @param unit npmatch's `street_unit` ("STE 300").
#' @return A character vector.
#' @export
md_place_key <- function(street_key, zip5 = NULL) {
  f <- .md_np_fn(c("np_addr_key", ".np_addr_key"))
  if (!is.null(f)) return(f(street_key, zip5))
  s <- toupper(as.character(street_key)); s[is.na(s)] <- ""
  z <- if (is.null(zip5)) rep("", length(s)) else as.character(zip5)
  z[is.na(z)] <- ""
  out <- ifelse(nzchar(s), paste(s, z), "")
  out[grepl(.md_pobox_pat, s)] <- ""
  out
}

#' @rdname md_place_key
#' @export
md_unit_id <- function(unit) {
  f <- .md_np_fn(c("np_unit_id", ".np_unit_id"))
  if (!is.null(f)) return(f(unit))
  v  <- toupper(as.character(unit))
  id <- sub(.md_unit_designator_re, "", v)
  id <- gsub("[^A-Z0-9]", "", id)
  ifelse(is.na(v) | !nzchar(id), NA_character_, id)
}

# npmatch's .np_pobox_pat and .np_unit_id() designator strip, ported.
.md_pobox_pat <- "^(P ?O ?BOX|P ?O ?B|BOX|P ?O) ?#? ?[0-9]+"
.md_unit_designator_re <- "^(#|[A-Z]+)[ .,]*#?[ .,]*"

.md_np_fn <- function(names) {
  if (!requireNamespace("npmatch", quietly = TRUE)) return(NULL)
  ns <- asNamespace("npmatch")
  for (nm in names) if (exists(nm, envir = ns, inherits = FALSE)) return(get(nm, envir = ns))
  NULL
}

.md_place_macros <- function(con) {
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP MACRO md_place_key(street_key, zip5) AS
      CASE WHEN coalesce(CAST(street_key AS VARCHAR), '') = ''
                OR regexp_matches(upper(CAST(street_key AS VARCHAR)), '%s') THEN ''
           ELSE upper(CAST(street_key AS VARCHAR)) || ' ' || coalesce(CAST(zip5 AS VARCHAR), '') END",
    .md_pobox_pat))
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP MACRO md_unit_id(unit) AS
      nullif(regexp_replace(regexp_replace(upper(CAST(unit AS VARCHAR)), '%s', ''),
                            '[^A-Z0-9]', '', 'g'), '')", .md_unit_designator_re))
  invisible(con)
}

#' Address-sharing statistics for a compiled reference
#'
#' What npmatch's `np_addr_freq()` computes, over exactly the rows of a
#' compiled reference: records per address, per address and suite, distinct
#' suites per address, suite coverage, distinct names and the top name's share,
#' and the class. [md_publish()] ships it in every bundle as
#' `addr_freq.parquet`, so a run against a slice of the reference (a state, a
#' shard) still reads the whole tier's counts, and [md_reference()] returns it
#' as `addr_freq`, the object `np_compare(addr_freq = )` takes.
#'
#' Calls `npmatch::np_addr_freq()` when the installed npmatch has it, so the
#' result is npmatch's by construction; otherwise a port of it.
#'
#' @param ref A compiled reference frame (`street_key`, `zip5`, `name_key`, and
#'   `street_unit_id` or `street_unit`).
#' @param share_min,unit_coverage_min npmatch's thresholds.
#' @return An object of class `np_addr_freq`.
#' @export
md_addr_freq <- function(ref, share_min = 10L, unit_coverage_min = 0.5) {
  units <- if ("street_unit_id" %in% names(ref)) ref$street_unit_id else md_unit_id(ref$street_unit)
  f <- .md_np_fn("np_addr_freq")
  if (!is.null(f)) {
    return(f(ref$street_key, ref$zip5, units, ref$name_key, share_min = share_min,
             unit_coverage_min = unit_coverage_min))
  }
  .md_addr_freq_port(ref$street_key, ref$zip5, units, ref$name_key, share_min, unit_coverage_min)
}

# npmatch's np_addr_freq() and .np_addr_class(), ported line for line.
.md_addr_freq_port <- function(street_keys, zip5, unit_ids, name_keys, share_min = 10L,
                               unit_coverage_min = 0.5) {
  a <- md_place_key(street_keys, zip5)
  u <- if (is.null(unit_ids)) rep(NA_character_, length(a)) else as.character(unit_ids)
  ok    <- nzchar(a)
  has_u <- ok & !is.na(u) & nzchar(u)
  addr  <- table(a[ok])
  aunit <- table(paste(a[has_u], u[has_u], sep = "|"))
  units <- tapply(u[has_u], a[has_u], function(v) length(unique(v)))
  n_addr <- stats::setNames(as.integer(addr), names(addr))
  n_unit <- stats::setNames(as.integer(units), names(units))
  wu  <- stats::setNames(as.integer(table(a[has_u])), names(table(a[has_u])))
  cov <- stats::setNames(rep(0, length(n_addr)), names(n_addr))
  cov[names(wu)] <- wu / n_addr[names(wu)]
  nk <- if (is.null(name_keys)) NULL else as.character(name_keys)
  if (!is.null(nk)) {
    n_names <- vapply(split(nk[ok], a[ok]), function(v) length(unique(v)), integer(1))
    top_shr <- vapply(split(nk[ok], a[ok]), function(v) max(table(v)) / length(v), numeric(1))
  } else {
    n_names <- stats::setNames(rep(NA_integer_, length(n_addr)), names(n_addr))
    top_shr <- stats::setNames(rep(NA_real_, length(n_addr)), names(n_addr))
  }
  cls <- rep("cluster", length(n_addr)); nm <- names(n_addr)
  big <- n_addr >= share_min
  uu <- n_unit[nm]; uu[is.na(uu)] <- 0L
  ts <- top_shr[nm]
  cls[big] <- "shared"
  cls[big & uu >= 2 & cov[nm] >= unit_coverage_min] <- "building"
  cls[big & !is.na(ts) & ts >= 0.5] <- "federated"
  cls[n_addr < 2] <- "single"
  structure(list(
    addr = n_addr, addr_unit = stats::setNames(as.integer(aunit), names(aunit)),
    units = n_unit, unit_coverage = cov, n_names = n_names[names(n_addr)],
    top_name_share = top_shr[names(n_addr)], class = stats::setNames(cls, nm),
    share_min = as.integer(share_min), unit_coverage_min = as.numeric(unit_coverage_min)),
    class = "np_addr_freq")
}

# An np_addr_freq as one long table, and back. kind 'addr' carries the
# per-address vectors; kind 'addr_unit' the per-suite counts.
.md_addr_freq_table <- function(af) {
  k <- names(af$addr)
  rbind(
    data.frame(kind = "addr", key = k, n = unname(af$addr),
               units = unname(af$units[k]), unit_coverage = unname(af$unit_coverage[k]),
               n_names = unname(af$n_names[k]), top_name_share = unname(af$top_name_share[k]),
               class = unname(af$class[k]), stringsAsFactors = FALSE),
    if (length(af$addr_unit)) data.frame(kind = "addr_unit", key = names(af$addr_unit),
               n = unname(af$addr_unit), units = NA_integer_, unit_coverage = NA_real_,
               n_names = NA_integer_, top_name_share = NA_real_, class = NA_character_,
               stringsAsFactors = FALSE))
}

.md_addr_freq_from_table <- function(t, share_min, unit_coverage_min) {
  a <- t[t$kind == "addr", , drop = FALSE]; u <- t[t$kind == "addr_unit", , drop = FALSE]
  # an empty vector carries no names, as np_addr_freq() returns it
  named <- function(x, n) if (length(x)) stats::setNames(x, n) else x
  v <- function(x) named(x, a$key)
  has_u <- !is.na(a$units)
  structure(list(
    addr = v(as.integer(a$n)), addr_unit = named(as.integer(u$n), u$key),
    units = named(as.integer(a$units[has_u]), a$key[has_u]),
    unit_coverage = v(as.numeric(a$unit_coverage)), n_names = v(as.integer(a$n_names)),
    top_name_share = v(as.numeric(a$top_name_share)), class = v(as.character(a$class)),
    share_min = as.integer(share_min), unit_coverage_min = as.numeric(unit_coverage_min)),
    class = "np_addr_freq")
}
