#' The `ein_relation` column list, named once
#'
#' Every ingest that writes `ein_relation` used to do it by **positional**
#' `INSERT ... SELECT`. That works until the table gains a column, at which point
#' all of them write the new column silently and wrongly - the failure is a
#' shifted value, not an error. Adding `controlled_512` forced the fix, and the
#' fix is to name the columns.
#'
#' Naming them in each ingest separately would recreate the same drift one level
#' up, so the list lives here and every writer calls this. A future column is
#' added in two places - the `CREATE TABLE` in [md_ingest_relations()] and this
#' vector - and every ingest keeps working.
#'
#' @param extra Columns this particular writer supplies beyond the common set.
#' @return A comma-separated column list for an `INSERT`.
#' @keywords internal
.md_relation_cols <- function(extra = NULL) {
  paste(c("relation_id", "ein_a", "ein_b", "related_name", "relation",
          "relation_raw", "evidence", "confidence", "first_year", "last_year",
          "n_obs", "source", "source_vintage", extra), collapse = ", ")
}

#' Build ein_relation from Schedule R and the group exemption structure
#'
#' Section 10 is emphatic that group and related-entity structure belongs in a relation table
#' rather than the name table: group subordinates and affiliate chapters are
#' *distinct EINs with near-identical names*, which is precisely the condition
#' that produces false matches. Registering "BOYS AND GIRLS CLUB OF SPRINGFIELD"
#' as an alias of the national EIN would make disambiguation worse, not better.
#'
#' matchdb's job is to record the relation with provenance. What to do with it -
#' collapse, veto, or ignore - is a matching decision and lives in `pfmatch`
#' (`R/dyads.R`, `R/affiliation.R`).
#'
#' @section Self-references are dropped, and that is not the same as worthless:
#' 4,133 filers list their own EIN as a related organisation. An edge from an
#' entity to itself is meaningless as a graph edge and distorts every degree
#' statistic computed over the table, so they are dropped and counted.
#'
#' But the first version of this note claimed they "carry no information", and
#' that was wrong. Checked against the filer's own BMF name, **61.7% of
#' self-references disclose a DIFFERENT name under the same EIN**, and the
#' examples are exactly the cases where IRS reporting structure and operating
#' reality diverge:
#'
#' \preformatted{
#'   BACKBONE HOUSING INC          -> Backbone Housing Inc (dba Starner Hill)
#'   FRANCISCAN HEALTH SYSTEM      -> Franciscan Health System FKA Franciscan ...
#'   EMBANKMENT SERVICES INC       -> EMBANKMENT SERVICES INC (ESI)
#'   AMERICAN POSTAL WORKERS UNION -> APWU EMPLOYEES' RETIREMENT 401K PLAN
#'   ALABAMA SCHOOL OF FINE ARTS FOUNDATION -> Alabama School of Fine Arts
#'   Catalight Foundation          -> Impact Together
#' }
#'
#' Those are DBAs, former names, acronyms, and genuinely distinct programmes
#' operating under one exemption - a parish and its school, a foundation and the
#' school it supports, a union and its benefit plan. Real information, and the
#' kind a matcher wants.
#'
#' It is not lost by dropping the edge, because what is useful about it is a
#' **name**, and names are not this function's job. `md_ingest_schedr()` already
#' writes every Part II counterparty name as an `observed` variant on the
#' counterparty's EIN - which for a self-reference is the filer's own EIN.
#' Measured: **4,116 of the 4,133 (99.6%) are already registered there**. The
#' edge is redundant; the alias is not, and it survives.
#'
#' @section `relation_raw` carries the controller, not the activity:
#' An earlier version put `SR_02_RLTD_ORG_PRIMARY_ACT` here, so Part II's raw
#' values read `HOSPITAL`, `HEALTHCARE`, `low-inc hsng`, `FUNDRAISING`. That is
#' the counterparty's *activity* - a property of the organisation, not of the
#' relation - and §4 reserves `relation_raw` for the source's own wording of the
#' **relation**.
#'
#' On this form that is the direct controlling entity, with an explicit `N/A`
#' where the filer states there is none. Population across 2009-2024:
#'
#' \preformatted{
#'   rows                        6,540,823
#'   direct controlling entity   4,501,572  (68.8%)
#'   explicit 'N/A'                950,837  (14.5%)
#'   primary activity            6,226,371  (95.2%)  <- no longer stored
#' }
#'
#' Losing the activity costs nothing here, and only here: Part II counterparties
#' are exempt organisations by definition and **119,865 of 119,865 (100%)
#' resolve into `entity`**, so each one's activity is available from its own
#' record. That is not true of Parts III and IV, whose counterparties resolve at
#' 5-9%.
#'
#' @section `controlled_512` is the sharpest signal the form carries:
#' `SR_02_RLTD_ORG_CTRL_512_X` - is the counterparty a §512(b)(13) controlled
#' entity - is a statutory yes/no, **93.1% populated** (2.07M true, 4.02M false)
#' against 68.8% for the controller name. It is what splits `related_entity`
#' into controlled-by versus merely-related, and it is the only column on the
#' form that answers that question directly rather than by inference from a name.
#'
#' It is encoded four ways across schema versions - `0`/`1` and `false`/`true` -
#' so both forms are normalised. Anything else becomes `NULL`: a blank box is
#' silence, not a denial, and coercing it to `FALSE` would invent 449,599
#' assertions nobody made.
#'
#' Aggregating to one row per pair uses `bool_or`, so a pair is `TRUE` if the
#' filer asserted control in **any** year. The alternative - `bool_and` - would
#' let one year with the box blank erase a control relationship stated in every
#' other year.
#'
#' Only Part II populates it. It is `NULL` for every other source, which is
#' honest: no other disclosure asks the question.
#'
#' @section Direction is fixed, not doubled:
#' A relation row reads **"`ein_b` is a `relation` of `ein_a`"**. Group rows are
#' stored once as (central, subordinate, `group_member`) rather than also as the
#' inverse `group_parent`, because storing both directions doubles the table to
#' say nothing new. Consumers that want the reverse read the pair backwards.
#'
#' @section Why group membership is not a clique:
#' 647,569 EINs carry a group exemption number, and 108 groups have more than a
#' thousand members - one has enough that a member-to-member clique would emit
#' hundreds of millions of pairs on its own. So membership is recorded as
#' parent-to-member, which is linear in group size.
#'
#' That requires identifying the parent, and the BMF `affiliation_code` does it.
#' The codes are **not ordered by seniority**, which is a trap worth spelling out
#' because an earlier version of this function fell into it:
#'
#' \preformatted{
#'   1  NETWORK-PARENT            parent, no group exemption
#'   2  NETWORK-INTERM            intermediate, no group exemption
#'   3  INDEPENDENT               unaffiliated
#'   6  GROUP-EXM-PARENT-REGULAR  parent of a group ruling
#'   7  GROUP-EXM-INTERM          intermediate within a group ruling
#'   8  GROUP-EXM-PARENT-CHURCH   parent of a group ruling, church or 501(c)(1)
#'   9  SUBORDINATE               subordinate in a group ruling
#' }
#'
#' **8 is a parent, not a subordinate.** Reading the codes as ascending
#' seniority puts 713 church parents on the member side of their own groups and
#' never uses them as parents. Parents are therefore `6` or `8`; members are `7`
#' or `9`.
#'
#' Intermediates are deliberately treated as members only. A `7` is genuinely
#' dual-role - a member of the central organisation and a parent to subordinates
#' beneath it - but nothing in the BMF says *which* subordinates report to which
#' intermediate, so emitting intermediate-to-subordinate links would be inventing
#' a hierarchy the data does not contain. One level, honestly.
#'
#' Groups with no coded parent produce no rows rather than a guessed one, and the
#' count of those is reported.
#'
#' @section Group exemption is not the whole of federated structure:
#' Measured on the active BMF, a GEN and a group-exemption role are two encodings
#' of one fact: no EIN carries a GEN without a group role, and only nine carry a
#' group role without a GEN.
#'
#' But **4,500 active organisations are coded `1` or `2` - network parents and
#' intermediates with no group exemption at all**. Affiliate structure does not
#' require the group exemption process, and this ingest does not reach it,
#' because a network has no GEN and therefore no key to join members on. This is
#' exactly why the `affiliate` relation (§4a) is defined and holds zero rows.
#' Worse,
#' network *subordinates* are not separately coded - only nine subordinates lack
#' a GEN - so those 3,459 network parents have members that cannot be identified
#' from the BMF at all.
#'
#' That gap is what Schedule R covers: disclosure does not depend on group
#' exemption, so an affiliate relationship outside a group ruling still appears
#' there. The two halves of this function are complementary rather than
#' overlapping.
#'
#' @section Schedule R gives both EINs, and sometimes only one:
#' Part II lists related tax-exempt organisations with an EIN, so most rows
#' resolve to a pair. Where the EIN is absent the row is still kept, with
#' `ein_b` null and `related_name` carrying the counterparty as written -
#' resolving a name to an EIN is a *matching* problem, which is npmatch's job,
#' not something an ingest should guess at.
#'
#' @param version Pinned `efile_related` version.
#' @param con A connection from [md_db()].
#' @return Row counts, invisibly.
#' @export
md_ingest_relations <- function(version = "v2_2", con = NULL) {
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))

  if (!DBI::dbExistsTable(con, "ein_relation")) {
    DBI::dbExecute(con, "
      CREATE TABLE ein_relation (
        relation_id    BIGINT,
        ein_a          VARCHAR,
        ein_b          VARCHAR,
        related_name   VARCHAR,
        relation       VARCHAR,
        relation_raw   VARCHAR,
        evidence       VARCHAR,
        confidence     DOUBLE,
        first_year     INTEGER,
        last_year      INTEGER,
        n_obs          INTEGER,
        source         VARCHAR,
        source_vintage VARCHAR,
        controlled_512 BOOLEAN)")
  }
  # Older databases predate controlled_512; adding it here keeps a rebuild and an
  # upgrade on the same path.
  if (!"controlled_512" %in% DBI::dbListFields(con, "ein_relation")) {
    DBI::dbExecute(con, "ALTER TABLE ein_relation ADD COLUMN controlled_512 BOOLEAN")
  }

  ## ---- Schedule R Part II -----------------------------------------------------
  dir <- md_path("sources", "efile_related", version)
  files <- list.files(dir, pattern = "^SR-P02-T01-.*[.]CSV$", full.names = TRUE)
  n_sr <- 0L
  if (!length(files)) {
    msg("  no Schedule R files in %s - skipping the affiliate half", dir)
  } else {
    vintage <- paste0("efile_related-", version)
    DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'efile_sched_r'")
    DBI::dbExecute(con, sprintf("
      CREATE OR REPLACE TEMP TABLE sr AS
      SELECT
        EIN2 AS ein_a,
        CASE WHEN length(regexp_replace(coalesce(SR_02_RLTD_ORG_EIN,''),'[^0-9]','','g')) = 9
             THEN 'EIN-' || substr(regexp_replace(SR_02_RLTD_ORG_EIN,'[^0-9]','','g'),1,2) ||
                  '-'    || substr(regexp_replace(SR_02_RLTD_ORG_EIN,'[^0-9]','','g'),3,9)
        END AS ein_b,
        trim(coalesce(SR_02_RLTD_ORG_NAME_L1,'') || ' ' ||
             coalesce(SR_02_RLTD_ORG_NAME_L2,''))         AS related_name,
        -- §4's contract for relation_raw is the source's own wording of the
        -- RELATION. On this form that is the direct controlling entity, or the
        -- explicit 'N/A' where the filer states there is none.
        nullif(trim(coalesce(SR_02_RLTD_ORG_CTRL_NAME_L1,'') || ' ' ||
                    coalesce(SR_02_RLTD_ORG_CTRL_NAME_L2,'')), '') AS ctrl_name,
        nullif(trim(SR_02_RLTD_ORG_CTRL_NA), '')          AS ctrl_na,
        -- §512(b)(13) controlled entity. The flag is encoded four ways across
        -- schema versions - 0/1 and false/true - so both are normalised and
        -- anything else becomes NULL rather than a guessed FALSE.
        CASE WHEN lower(trim(coalesce(SR_02_RLTD_ORG_CTRL_512_X,''))) IN ('1','true','x','yes')
             THEN TRUE
             WHEN lower(trim(coalesce(SR_02_RLTD_ORG_CTRL_512_X,''))) IN ('0','false','no')
             THEN FALSE END                                AS controlled_512,
        TRY_CAST(TAX_YEAR AS INTEGER)                     AS tax_year
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE,
                         quote='\"', escape='\"')
      WHERE EIN2 IS NOT NULL AND regexp_matches(EIN2,'^EIN-[0-9]{2}-[0-9]{7}$')",
      file.path(dir, "SR-P02-T01-*.CSV")))

    # Self-references are dropped, and the count is reported rather than absorbed.
    # See the roxygen: they are not noise, but what is useful about them is a
    # NAME, and md_ingest_schedr() already captures it.
    n_self <- DBI::dbGetQuery(con, "
      SELECT count(DISTINCT ein_a) AS n FROM sr WHERE ein_a = ein_b")$n

    base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m
    n_sr <- DBI::dbExecute(con, sprintf("
      INSERT INTO ein_relation (%s)
      SELECT %s + row_number() OVER (), ein_a, ein_b, related_name, 'related_entity',
             relation_raw, 'schedule_r_part_ii', NULL,
             first_year, last_year, n_obs, 'efile_sched_r', '%s', c512
      FROM (
        SELECT ein_a, ein_b,
               max(related_name) AS related_name,
               -- a named controller outranks an 'N/A' asserted in another year
               coalesce(max(ctrl_name), max(ctrl_na)) AS relation_raw,
               -- TRUE if the filer ever asserted control in any filing year: a
               -- year with the box blank is silence, not a denial
               bool_or(controlled_512) AS c512,
               min(tax_year) AS first_year, max(tax_year) AS last_year,
               count(*) AS n_obs
        FROM sr
        WHERE (ein_b IS NOT NULL OR trim(related_name) <> '')
          AND (ein_b IS NULL OR ein_b <> ein_a)
        GROUP BY ein_a, ein_b)",
      .md_relation_cols("controlled_512"), format(base, scientific = FALSE), vintage))

    unresolved <- DBI::dbGetQuery(con, "
      SELECT count(*) AS n FROM ein_relation
      WHERE source = 'efile_sched_r' AND ein_b IS NULL")$n
    msg("  Schedule R Part II: %s related_entity pairs, %s with no counterparty EIN",
        format(n_sr, big.mark = ","), format(unresolved, big.mark = ","))
    msg("  %s self-references dropped; their names survive as schedr observed variants",
        format(n_self, big.mark = ","))
    md_record_vintage(con, "efile_related", version, "ein_relation:related_entity",
                      as.integer(n_sr), build_note = "md_ingest_relations()")
  }

  ## ---- group exemption --------------------------------------------------------
  DBI::dbExecute(con, "DELETE FROM ein_relation WHERE source = 'bmf_gen'")
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE gen AS
    SELECT ein, group_exemption_number AS gen, affiliation_code
    FROM entity
    WHERE group_exemption_number IS NOT NULL
      AND group_exemption_number NOT IN ('', '0000')")

  base <- DBI::dbGetQuery(con, "SELECT coalesce(max(relation_id),0) AS m FROM ein_relation")$m
  n_gen <- DBI::dbExecute(con, sprintf("
    INSERT INTO ein_relation (%s)
    SELECT %s + row_number() OVER (), p.ein, m.ein, NULL, 'group_member',
           'affiliation_code=' || coalesce(m.affiliation_code,'?'),
           'bmf_group_exemption', NULL, NULL, NULL, NULL,
           'bmf_gen', 'bmf_unified-v2026-08-11'
    FROM gen p JOIN gen m ON p.gen = m.gen AND p.ein <> m.ein
    WHERE p.affiliation_code IN ('6','8')
      AND m.affiliation_code IN ('7','9')",
    .md_relation_cols(), format(base, scientific = FALSE)))

  orphan <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM (
      SELECT gen FROM gen GROUP BY gen
      HAVING sum(CASE WHEN affiliation_code = '6' THEN 1 ELSE 0 END) = 0)")$n
  msg("  group exemption: %s parent-to-member pairs; %s groups have no coded parent",
      format(n_gen, big.mark = ","), format(orphan, big.mark = ","))
  md_record_vintage(con, "bmf_unified", "v2026-08-11", "ein_relation:group_member",
                    as.integer(n_gen), build_note = "md_ingest_relations()")

  total <- .md_n(con, "ein_relation")
  msg("  ein_relation: %s rows", format(total, big.mark = ","))
  invisible(stats::setNames(c(n_sr, n_gen, total),
                            c("part_ii", "group_member", "total")))
}

#' @rdname md_layers
#' @export
md_relations <- function() {
  c("group_parent", "group_member", "affiliate", "dyad_substitutable", "successor")
}
