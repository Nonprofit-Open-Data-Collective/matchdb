#' Add related entities disclosed on 527 Schedule R
#'
#' Form 8871 Schedule R is the political-organisation analogue of Form 990
#' Schedule R: a 527 names the organisations it is connected to. `?md_irs527_shape`
#' profiles the file; this loads it.
#'
#' @section Every row lands with `ein_b` NULL, and that is the source's shape:
#' The file gives `(527 EIN) -> (ENTITY_NAME, address)`. There is no counterparty
#' EIN anywhere in it. Resolving a name to an EIN is a *matching* problem and
#' belongs to `npmatch`, so these rows record the counterparty by name and leave
#' `ein_b` open. `PLAN.md` §4 made `ein_b` nullable for exactly this source.
#'
#' The gap is not small and pretending otherwise would mislead a consumer: of
#' 10,597 distinct counterparty names, **1,564 (14.8%) exactly match a BMF legal
#' name**. The rest are sponsoring corporations, unions and trade associations
#' that are largely outside the exempt universe altogether. A consumer treating
#' `related_name` as resolvable should expect roughly one in seven to resolve.
#'
#' @section The whole tail maps to `related_entity`, deliberately:
#' `ENTITY_RELATIONSHIP` is free text with 528 distinct values. `Connected`
#' (54,660) and `Affiliated` (5,801) are 97.4% of rows; the tail runs
#' `Sponsor` (103), `Partner` (73), `Connected Organization` (56), and on down
#' to single-occurrence strings.
#'
#' Every one of them maps to `relation = 'related_entity'` (§4a). A "connected
#' organisation" is the body that established, administers or funds the political
#' organisation - a support and control tie, not loose coordination. That places
#' it with Schedule R rather than in the `coalition` band, even though the
#' counterparty is usually a corporation or union rather than a nonprofit.
#'
#' The alternative - reading sub-types out of the free text - would manufacture a
#' taxonomy the filers were never asked to use, and
#' `Common candidate-CA 33rd Assembly Dist.` is not a relation type.
#' `relation_raw` keeps the original string, so a later mapping can be derived
#' without re-ingesting. That is the §4 contract for `relation_raw` and this is
#' the source it was written for.
#'
#' Note what this source is *not*: two organisations that both appear as
#' connected to the same political organisation are a `coalition`, and that is a
#' derived co-membership over a shared counterparty, never a stored edge. §4a.
#'
#' `None` (42 rows) is kept rather than dropped: the filer still named an entity
#' on Schedule R and merely declined to characterise the tie. The disclosure is
#' the fact; the label is commentary.
#'
#' @section What is dropped:
#' 171 rows name the filer itself as its own related entity. Those are
#' self-loops and carry no information, so they are removed and counted.
#'
#' Rows are then deduplicated to one per `(ein_a, related_name, relation_raw)`
#' with `n_obs` recording how many filings asserted it - each amendment is a
#' fresh row in the source, so the raw count overstates distinct relations.
#'
#' @section What must not happen:
#' The counterparty name must never become a `name` variant on the 527's EIN.
#' §10 is explicit that affiliates are not DBAs, and this source most invites the
#' error: "ASSOCIATION OF SAFETY GROUPS" is a different body from "ASGM PAC", and
#' aliasing them manufactures precisely the false match the database exists to
#' prevent. This function writes to `ein_relation` and nothing else.
#'
#' @param con A connection from [md_db()].
#' @param path Path to `2024-11-POL-ORGS-SCHED-R.csv`.
#' @return Row counts, invisibly.
#' @export
md_ingest_irs527_related <- function(con = NULL, path = NULL) {
  if (is.null(path)) {
    path <- md_path("sources", "irs527_related", "v2024-11-15",
                    "2024-11-POL-ORGS-SCHED-R.csv")
  }
  if (!file.exists(path)) stop("no 527 Schedule R at ", path, call. = FALSE)

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- "irs527_related-v2024-11-15"
  msg <- function(...) message(sprintf(...))

  # ALL_VARCHAR because EIN is a zero-padded identifier, not a number. The
  # sibling 8871 file segfaults data.table::fread(); DuckDB reads both cleanly.
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE sr527 AS
    SELECT
      'EIN-' || substr(d,1,2) || '-' || substr(d,3,9) AS ein_a,
      trim(ENTITY_NAME)                               AS related_name,
      coalesce(nullif(trim(ENTITY_RELATIONSHIP),''), '(unstated)') AS relation_raw
    FROM (
      SELECT lpad(regexp_replace(EIN,'[^0-9]','','g'), 9, '0') AS d,
             ENTITY_NAME, ENTITY_RELATIONSHIP, ORG_NAME
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, quote='\"', escape='\"')
      WHERE nullif(trim(ENTITY_NAME),'') IS NOT NULL
        AND length(regexp_replace(EIN,'[^0-9]','','g')) = 9
        AND upper(trim(ENTITY_NAME)) <> upper(trim(ORG_NAME))
    )", gsub("\\\\", "/", path)))

  n_raw  <- .md_n(con, "sr527")
  n_self <- DBI::dbGetQuery(con, sprintf("
    SELECT count(*) AS n FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, quote='\"', escape='\"')
    WHERE upper(trim(ENTITY_NAME)) = upper(trim(ORG_NAME))", gsub("\\\\", "/", path)))$n
  msg("  %s disclosure rows after dropping %s self-references",
      format(n_raw, big.mark = ","), format(n_self, big.mark = ","))

  DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'irs527_sched_r'")
  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m

  n_new <- DBI::dbExecute(con, sprintf("
    INSERT INTO ein_relation
    SELECT %s + row_number() OVER (), ein_a, NULL, related_name, 'related_entity',
           relation_raw, 'irs527_schedule_r', NULL,
           NULL, NULL, n_obs, 'irs527_sched_r', '%s'
    FROM (
      SELECT ein_a, related_name, relation_raw, count(*) AS n_obs
      FROM sr527 GROUP BY ein_a, related_name, relation_raw)",
    format(base, scientific = FALSE), vintage))
  msg("  %s related_entity rows added (ein_b NULL by construction)",
      format(n_new, big.mark = ","))

  known <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM (SELECT DISTINCT ein_a FROM sr527) s
    JOIN entity e ON e.ein = s.ein_a")$n
  n_ein <- DBI::dbGetQuery(con, "SELECT count(DISTINCT ein_a) AS n FROM sr527")$n
  msg("  %s of %s disclosing EINs are already in `entity`",
      format(known, big.mark = ","), format(n_ein, big.mark = ","))

  md_record_vintage(con, "irs527_related", "v2024-11-15",
                    "ein_relation:related_entity", as.integer(n_new),
                    build_note = "md_ingest_irs527_related(); ein_b unresolved")
  msg("  ein_relation: %s rows", format(.md_n(con, "ein_relation"), big.mark = ","))
  invisible(stats::setNames(c(n_raw, n_self, n_new),
                            c("rows", "self_refs", "added")))
}
