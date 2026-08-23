#' Add the other three identification parts of Schedule R
#'
#' `md_ingest_relations()` reads Schedule R **Part II** - related *tax-exempt*
#' organisations. The form has three more identification parts, and all three
#' name a counterparty with an EIN:
#'
#' \describe{
#'   \item{Part I}{disregarded entities - `efile_disregarded`}
#'   \item{Part III}{related organisations taxable as a partnership - `efile_related_ptr`}
#'   \item{Part IV}{related organisations taxable as a corporation or trust - `efile_related_corp`}
#' }
#'
#' @section These counterparties are mostly not nonprofits, and the rate is the point:
#' Part II counterparties are exempt organisations by definition, so their EINs
#' resolve well. These do not. Measured on Part I across 2009-2024:
#'
#' \preformatted{
#'   rows                              2,000,291
#'   with a counterparty EIN             317,232
#'   distinct counterparty EINs           35,306
#'   resolving to a known `entity`         4,763  (13.5%)
#' }
#'
#' 13.5% is close to the 14.8% seen on 527 Schedule R, and for the same reason: a
#' disregarded entity is usually a single-member LLC with no exempt status of its
#' own, and a taxable subsidiary is a C-corp. They are outside the BMF universe.
#'
#' Rows are still written with `ein_b` populated, because unlike the 527 file
#' these sources *give* the EIN - an EIN that is real but unknown to matchdb is a
#' different thing from an EIN that was never disclosed. A consumer joining
#' `ein_b` to `entity` should expect roughly one in seven to land, and the
#' per-source rate is reported on every run.
#'
#' @section Part I is a different relation from Parts III and IV:
#' See the §4a vocabulary. Parts III and IV describe organisations the filer
#' controls, owns a share of, or shares governance with - `related_entity`. Part I
#' describes an entity with **no separate tax existence at all**, whose activity
#' is reported on the filer's own return. That is a tighter tie than any
#' disclosure on the rest of the form, so it gets its own value,
#' `disregarded_entity`.
#'
#' The part is additionally carried in `evidence`
#' (`schedule_r_part_i_disregarded`, `..._part_iii_partnership`,
#' `..._part_iv_corporation`), so the taxable/exempt distinction inside
#' `related_entity` survives without needing its own enum value.
#'
#' @section A deferred question about disregarded entities:
#' Because a disregarded entity has no separate tax existence, its name is
#' arguably a name the *parent* operates under - closer to a `dba` than to a
#' relation at all. That would be a `name` row on the parent's EIN.
#'
#' It is deliberately **not** done here. §10 forbids casually aliasing one
#' organisation's name onto another, and the difference between "disregarded for
#' tax" and "the same organisation for matching" has not been measured.
#' Recording the relation keeps the option open; writing the alias would not be
#' reversible.
#'
#' @section An ingest hazard, and it is not the one documented for 527:
#' Pre-2013 files carry doubled quotes inside *unquoted* fields
#' (`PLEASE SEE SCHEDULE ""O"".`), which is malformed CSV and aborts a strict
#' parse partway through 2010. `quote='"', escape='"', ignore_errors=TRUE` reads
#' them. Early years are also much wider - Part I is 96 columns in 2012 against
#' 34 in 2013 - so `union_by_name=TRUE` is required, and most rows are blank
#' padding rather than data.
#'
#' @param con A connection from [md_db()].
#' @param which One or more of `"disregarded"`, `"partnership"`, `"corporation"`.
#' @return Row counts per part, invisibly.
#' @export
md_ingest_schedr_parts <- function(con = NULL,
                                   which = c("disregarded", "partnership", "corporation")) {
  which <- match.arg(which, several.ok = TRUE)
  spec <- list(
    disregarded = list(src = "efile_disregarded",   tbl = "SR-P01-T01-ID-DISREGARDED-ENTITIES",
                       pre = "SR_01_DISREG_ENTITY", tag = "efile_sr_p01", rel = "disregarded_entity",
                       ev  = "schedule_r_part_i_disregarded",  raw = "Part I disregarded entity"),
    partnership = list(src = "efile_related_ptr",   tbl = "SR-P03-T01-ID-RLTD-ORGS-TAXABLE-PARTNERSHIP",
                       pre = "SR_03_RLTD_ORG_PTR",  tag = "efile_sr_p03", rel = "related_entity",
                       ev  = "schedule_r_part_iii_partnership", raw = "Part III taxable partnership"),
    corporation = list(src = "efile_related_corp",  tbl = "SR-P04-T01-ID-RLTD-ORGS-TAXABLE-CORPORATION",
                       pre = "SR_04_RLTD_ORG_CORP", tag = "efile_sr_p04", rel = "related_entity",
                       ev  = "schedule_r_part_iv_corporation",  raw = "Part IV taxable corporation or trust"))

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  out <- list()

  for (w in which) {
    s <- spec[[w]]
    glob <- md_path("sources", s$src, "v2_2", paste0(s$tbl, "-*.CSV"))
    files <- Sys.glob(glob)
    if (!length(files)) { msg("  %s: no files, skipped", w); next }
    msg("%s (%d files)", w, length(files))

    DBI::dbExecute(con, sprintf("
      CREATE OR REPLACE TEMP TABLE srp AS
      SELECT 'EIN-' || substr(a,1,2) || '-' || substr(a,3,9) AS ein_a,
             CASE WHEN length(b) = 9
                  THEN 'EIN-' || substr(b,1,2) || '-' || substr(b,3,9) END AS ein_b,
             nm, ty
      FROM (
        SELECT lpad(regexp_replace(ORG_EIN,'[^0-9]','','g'), 9, '0') AS a,
               regexp_replace(coalesce(%s_EIN,''), '[^0-9]','','g')  AS b,
               nullif(trim(%s_NAME_L1), '')                          AS nm,
               try_cast(TAX_YEAR AS INT)                             AS ty
        FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE,
                           quote='\"', escape='\"', ignore_errors=TRUE)
        WHERE length(regexp_replace(ORG_EIN,'[^0-9]','','g')) = 9)
      WHERE (ein_b IS NOT NULL OR nm IS NOT NULL)
        AND coalesce(b,'') <> a", s$pre, s$pre, gsub("\\\\", "/", glob)))

    prof <- DBI::dbGetQuery(con, "
      SELECT count(*) AS n, count(ein_b) AS with_ein,
             count(DISTINCT ein_b) AS distinct_b,
             count(DISTINCT ein_b) FILTER (
               WHERE ein_b IN (SELECT ein FROM entity)) AS resolvable
      FROM srp")
    msg("  %s disclosure rows; %s carry an EIN; %s of %s distinct counterparties are in `entity` (%.1f%%)",
        format(prof$n, big.mark = ","), format(prof$with_ein, big.mark = ","),
        format(prof$resolvable, big.mark = ","), format(prof$distinct_b, big.mark = ","),
        100 * prof$resolvable / max(prof$distinct_b, 1))

    DBI::dbExecute(con, sprintf("DELETE FROM ein_relation WHERE source = '%s'", s$tag))
    base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m
    n_new <- DBI::dbExecute(con, sprintf("
      INSERT INTO ein_relation (%s)
      SELECT %s + row_number() OVER (), ein_a, ein_b, nm, '%s',
             '%s', '%s', NULL, fy, ly, n, '%s', '%s'
      FROM (SELECT ein_a, ein_b, max(nm) AS nm, min(ty) AS fy, max(ty) AS ly,
                   count(*) AS n
            FROM srp GROUP BY ein_a, ein_b)",
      .md_relation_cols(), format(base, scientific = FALSE), s$rel, s$raw, s$ev, s$tag,
      paste0(s$src, "-v2_2")))
    msg("  %s edges added", format(n_new, big.mark = ","))

    md_source_pin(s$src, sort(files), version = "v2_2")
    md_record_vintage(con, s$src, "v2_2", paste0("ein_relation:", s$rel), as.integer(n_new),
                      build_note = sprintf("md_ingest_schedr_parts('%s')", w))
    out[[w]] <- c(rows = prof$n, with_ein = prof$with_ein, added = n_new)
  }
  msg("ein_relation: %s rows", format(.md_n(con, "ein_relation"), big.mark = ","))
  invisible(out)
}
