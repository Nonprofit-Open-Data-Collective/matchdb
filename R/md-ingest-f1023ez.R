#' Ingest Form 1023-EZ approvals
#'
#' The 1023-EZ is the streamlined application for recognition of exemption. Its
#' approval extracts give, per approved organisation, the **name and address as
#' the organisation itself wrote them at application**, and an NTEE code the
#' organisation selected.
#'
#' @section Why this source earns its place:
#' Every other NTEE input here traces to the same assignment. The crosswalk's
#' `ntee_current` agrees with the BMF 99.96% of the time - it is the same value,
#' not a second opinion (`?md_ingest_ntee`). The 1023-EZ code is genuinely
#' independent: the organisation chose it, before any IRS or NCCS processing
#' touched it. That makes it the only available cross-check on a classification
#' the rest of the database takes on trust.
#'
#' The name is independent in the same way. A 1023-EZ name is what the founders
#' filed under, which may differ from the BMF legal name recorded later, and
#' those differences are exactly the variants a matcher needs.
#'
#' @section Personal data is not ingested:
#' Columns 18-57 of the source are five officers' names and **home addresses**.
#' They are never parsed - [md_xlsx_to_csv()] takes a column list, so unwanted
#' columns are not read rather than read and dropped. matchdb is a database of
#' organisations.
#'
#' @param version Pinned version directory, e.g. `"v2014-2023"`.
#' @param con A connection from [md_db()].
#' @param new_entity_layer Layer under which to admit approved organisations that
#'   appear in no BMF release. `NULL`, the default, holds them back instead. No
#'   value in the frozen enumeration (section 3a) describes an organisation the
#'   IRS granted exemption to but which reached no BMF release: `filer_only`
#'   means observed on a 990-series filing, and an approval is not a filing.
#'   Set this once that question is settled.
#' @param reconvert Redo the xlsx-to-CSV step even if a CSV is already present.
#' @return Row counts, invisibly.
#' @export
md_ingest_f1023ez <- function(version = "v2014-2023", con = NULL,
                              new_entity_layer = "approved_only",
                              reconvert = FALSE) {
  dir <- md_path("sources", "f1023ez", version)
  books <- list.files(dir, pattern = "[.]xlsx$", full.names = TRUE)
  if (!length(books)) stop("no 1023-EZ workbooks in ", dir, call. = FALSE)

  KEEP <- c("Ein", "Orgname1", "Orgname2", "Address", "City", "State",
            "Zip", "Zippl4", "Nteecode")
  # The IRS names the workbooks three ways (?md_f1023ez_urls), so each CSV is
  # named by its year. Keeping the workbook's name would let the underscore
  # files (2014-2019) miss the glob below and drop out without an error.
  yrs <- .md_f1023ez_year(books)
  if (anyDuplicated(yrs)) {
    stop("two 1023-EZ workbooks for one year: ",
         paste(basename(books[yrs %in% yrs[duplicated(yrs)]]), collapse = ", "),
         call. = FALSE)
  }
  for (i in seq_along(books)) {
    b <- books[i]
    csv <- file.path(dir, sprintf("f1023ez-approvals-%s.csv", yrs[i]))
    if (reconvert || !file.exists(csv)) {
      message("converting ", basename(b))
      md_xlsx_to_csv(b, columns = KEEP, out = csv)
    }
  }

  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  vintage <- paste0("f1023ez-", version)
  msg <- function(...) message(sprintf(...))

  glob <- file.path(dir, "f1023ez-approvals-*.csv")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE ez AS
    SELECT
      'EIN-' || substr(d,1,2) || '-' || substr(d,3,9) AS ein,
      trim(coalesce(Orgname1,'') || ' ' || coalesce(Orgname2,'')) AS name_raw,
      Address AS street_raw, City AS city_raw, upper(trim(State)) AS state,
      substr(regexp_replace(coalesce(Zip,''),'[^0-9]','','g'),1,5) AS zip5,
      upper(trim(coalesce(Nteecode,''))) AS ntee_code,
      TRY_CAST(regexp_extract(filename, '([0-9]{4})[.]csv$', 1) AS INTEGER) AS approval_year
    FROM (
      SELECT *, lpad(regexp_replace(coalesce(Ein,''),'[^0-9]','','g'),9,'0') AS d
      FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE, filename=TRUE)
      WHERE length(regexp_replace(coalesce(Ein,''),'[^0-9]','','g')) BETWEEN 1 AND 9
    )", glob))
  n_raw <- .md_n(con, "ez")
  msg("  %s approvals", format(n_raw, big.mark = ","))

  # Idempotence. This is a full load keyed on source_vintage (section 10), so a re-run
  # replaces rather than appends. Without this a second call silently doubles
  # every row it wrote.
  for (tb in c("name", "address")) {
    DBI::dbExecute(con, sprintf("DELETE FROM %s WHERE source = 'f1023ez'", tb))
  }

  ## ---- how much of this is new? ---------------------------------------------
  known <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n,
           sum(CASE WHEN e.ein IS NULL THEN 1 ELSE 0 END) AS absent_from_db
    FROM (SELECT DISTINCT ein FROM ez) z LEFT JOIN entity e USING (ein)")
  msg("  %s distinct EINs, %s absent from the database",
      format(known$n, big.mark = ","), format(known$absent_from_db, big.mark = ","))

  # An approved 1023-EZ organisation that appears in no BMF release does not fit
  # any frozen layer (section 3a): `filer_only` means observed on a 990-series filing,
  # and an approval is not a filing. Minting an entity under a layer that does
  # not describe it would put a wrong answer in the provenance column, which is
  # the one column that has to be right.
  #
  # So by default those rows are held back rather than orphaned or mislabelled,
  # and the count is reported. Pass a layer explicitly to admit them once the
  # enumeration question is settled.
  if (is.null(new_entity_layer)) {
    DBI::dbExecute(con, "
      CREATE OR REPLACE TEMP TABLE ez_keep AS
      SELECT z.* FROM ez z JOIN entity e USING (ein)")
    held <- n_raw - .md_n(con, "ez_keep")
    if (held > 0) {
      msg("  holding back %s approvals for %s EINs in no BMF release -",
          format(held, big.mark = ","), format(known$absent_from_db, big.mark = ","))
      msg("    no frozen layer describes them. See ?md_ingest_f1023ez.")
    }
  } else {
    DBI::dbExecute(con, sprintf("
      INSERT INTO entity (ein, layer, active, source_vintage)
      SELECT DISTINCT z.ein, '%s', FALSE, '%s'
      FROM ez z LEFT JOIN entity e USING (ein) WHERE e.ein IS NULL",
      new_entity_layer, vintage))
    DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE ez_keep AS SELECT * FROM ez")
    msg("  admitted %s new EINs as layer = %s",
        format(known$absent_from_db, big.mark = ","), new_entity_layer)
  }
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE ez AS SELECT * FROM ez_keep")

  ## ---- names ----------------------------------------------------------------
  # mode(name_raw) was used here previously and is exactly the non-deterministic
  # tiebreak md_modal_sql() exists to replace (?md_modal_sql; PAIN-POINTS.md #1).
  DBI::dbExecute(con, "
    CREATE OR REPLACE TEMP TABLE ez_name_key AS
    SELECT *, trim(regexp_replace(regexp_replace(upper(name_raw),'[^A-Z0-9 ]','','g'),
                                  ' +',' ','g')) AS name_key
    FROM ez WHERE trim(name_raw) <> ''")
  base_name <- DBI::dbGetQuery(con, "SELECT coalesce(max(name_id),0) AS m FROM name")$m
  n_name <- DBI::dbExecute(con, sprintf("
    INSERT INTO name (name_id, ein, name_raw, variant_class, source,
                      source_vintage, n_obs, n_corroborators, first_year, last_year)
    WITH agg AS (
      SELECT ein, name_key, count(*) AS n_obs,
             min(approval_year) AS first_year, max(approval_year) AS last_year
      FROM ez_name_key GROUP BY 1,2
    ), %s
    SELECT %s + row_number() OVER (), a.ein, s.name_raw, 'legal', 'f1023ez', '%s',
           a.n_obs, NULL, a.first_year, a.last_year
    FROM agg a JOIN modal_name_raw s USING (ein, name_key)
    WHERE s.rk = 1",
    md_modal_sql("ez_name_key", c("ein", "name_key"), "name_raw"),
    format(base_name, scientific = FALSE), vintage))
  msg("  %s names (variant_class = legal, source = f1023ez)",
      format(n_name, big.mark = ","))

  ## ---- addresses -------------------------------------------------------------
  # historical, not mailing: an application address is where the organisation was
  # when it applied, which for a 2014 approval is a decade stale. Treating it as
  # current is how a reference starts matching organisations to addresses they
  # left long ago.
  # mode(street_raw)/mode(city_raw) were used here previously -- the same
  # non-deterministic tiebreak fixed in the name block above and in the
  # Schedule I ingest (PAIN-POINTS.md #1); moved onto md_modal_sql() here too.
  base_addr <- DBI::dbGetQuery(con, "SELECT coalesce(max(address_id),0) AS m FROM address")$m
  addr_by <- c("ein", "state", "zip5")
  n_addr <- DBI::dbExecute(con, sprintf("
    INSERT INTO address (address_id, ein, name_id, street_raw, city_raw, state,
                         zip5, variant_class, spell_rank, source, source_vintage,
                         n_obs, first_vintage, last_vintage)
    WITH agg AS (
      SELECT ein, state, zip5, count(*) AS n_obs,
             min(approval_year)::VARCHAR AS first_vintage,
             max(approval_year)::VARCHAR AS last_vintage
      FROM ez WHERE coalesce(street_raw,'') <> '' GROUP BY 1,2,3
    ), %s, %s
    SELECT %s + row_number() OVER (), a.ein, NULL, st.street_raw, ct.city_raw,
           a.state, a.zip5, 'historical', 1, 'f1023ez', '%s', a.n_obs,
           a.first_vintage, a.last_vintage
    FROM agg a
    JOIN modal_street_raw st USING (ein, state, zip5)
    JOIN modal_city_raw   ct USING (ein, state, zip5)
    WHERE st.rk = 1 AND ct.rk = 1",
    md_modal_sql("(SELECT * FROM ez WHERE coalesce(street_raw,'') <> '')", addr_by, "street_raw"),
    md_modal_sql("(SELECT * FROM ez WHERE coalesce(street_raw,'') <> '')", addr_by, "city_raw"),
    format(base_addr, scientific = FALSE), vintage))
  msg("  %s addresses (variant_class = historical)", format(n_addr, big.mark = ","))

  ## ---- the independent NTEE opinion ------------------------------------------
  # Kept as observations rather than folded into entity's resolved triple. The
  # triple records one value and the rule that chose it; adding a second source
  # silently would make the recorded rule a lie. This table is the input a
  # revised rule would read.
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE ntee_observed AS
    SELECT ein, ntee_code, 'f1023ez' AS source, min(approval_year) AS first_year,
           max(approval_year) AS last_year, count(*) AS n_obs, '%s' AS source_vintage
    FROM ez WHERE ntee_code <> '' GROUP BY 1,2", vintage))
  n_ntee <- .md_n(con, "ntee_observed")
  msg("  %s observed NTEE codes", format(n_ntee, big.mark = ","))

  for (tb in list(c("name:f1023ez", n_name), c("address:f1023ez", n_addr),
                  c("ntee_observed", n_ntee))) {
    md_record_vintage(con, "f1023ez", version, tb[1], as.integer(tb[2]),
                      build_note = "md_ingest_f1023ez()")
  }
  invisible(stats::setNames(c(n_name, n_addr, n_ntee),
                            c("names", "addresses", "ntee_observed")))
}

#' Compare the 1023-EZ NTEE against the resolved value
#'
#' The cross-check the second opinion exists for. Reports how often the code an
#' organisation chose for itself matches the one the database resolved, and by
#' which rule.
#'
#' @param con A connection from [md_db()].
#' @return A data frame, invisibly.
#' @export
md_ntee_crosscheck <- function(con = NULL) {
  own <- is.null(con)
  if (own) { con <- md_db(read_only = TRUE); on.exit(md_db_close(con), add = TRUE) }
  out <- DBI::dbGetQuery(con, "
    SELECT e.ntee_rule,
           count(*) AS n,
           sum(CASE WHEN substr(o.ntee_code,1,3) = substr(e.ntee_code,1,3)
                    THEN 1 ELSE 0 END) AS agree_3char,
           round(100.0 * sum(CASE WHEN substr(o.ntee_code,1,3) = substr(e.ntee_code,1,3)
                    THEN 1 ELSE 0 END) / count(*), 1) AS pct
    FROM ntee_observed o JOIN entity e USING (ein)
    WHERE o.source = 'f1023ez' AND e.ntee_code IS NOT NULL
    GROUP BY 1 ORDER BY n DESC")
  print(out)
  invisible(out)
}

# The approval year of each workbook: the four digits right before `.xlsx`.
# Not the first four digits in the name, which are the 1023 in "f1023ez".
.md_f1023ez_year <- function(books) {
  b <- basename(books)
  ok <- grepl("(19|20)[0-9]{2}[.]xlsx$", b, ignore.case = TRUE)
  if (!all(ok)) {
    stop("no year before .xlsx in: ", paste(b[!ok], collapse = ", "), call. = FALSE)
  }
  sub("^.*((19|20)[0-9]{2})[.]xlsx$", "\\1", b, ignore.case = TRUE)
}
