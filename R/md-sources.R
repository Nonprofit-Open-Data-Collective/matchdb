#' The source registry
#'
#' Every upstream input matchdb ingests, with the URL it comes from. This is the
#' inventory the build works from; nothing is fetched that is not listed here.
#'
#' Note the `pointer` column. Some upstream publishers expose a stable
#' `latest/` URL whose *contents* change without notice. Those cannot be cited
#' as provenance - "the BMF as of latest" means nothing six months on - so
#' [md_source_pin()] resolves a pointer to a concrete version before any ingest
#' reads it, and the ingest reads the pinned copy rather than the URL.
#'
#' @return A `data.frame`, one row per source.
#' @export
md_sources <- function() {
  ef   <- function(tbl) paste0(.md_efile_base, tbl, "-%d.CSV")
  meta <- function(f) paste0(.md_nccs_meta, f, ".csv")
  rows <- list(
    c("bmf_unified",       "entity, name, address",
      "https://nccsdata.s3.dualstack.us-east-1.amazonaws.com/geocoding/unified-bmf/latest/bmf_unified_geocoded.parquet",
      "parquet", "TRUE",  NA, "612 MB",
      "active + inactive, geocoded; the `latest/` key is overwritten in place"),
    c("bmf_active",        "entity, name, address",
      "https://nccsdata.s3.dualstack.us-east-1.amazonaws.com/crosswalks/npmatch/bmf_2026_01_processed.csv",
      "csv", "FALSE", NA, "1.6 GB",
      "monthly active BMF; 1,924,822 rows in the 2026-01 vintage"),
    c("schedi",            "name, address (observed)",
      ef("SI-P02-T01-GRANTS-US-ORGS-GOVTS"), "csv", "FALSE", "2009:2024", "3.5 GB",
      "Schedule I Part II: (name, address) -> EIN as written by grantmakers"),
    c("efile_header",      "entity (filer_only), name, address",
      ef("F9-P00-T00-HEADER"), "csv", "FALSE", "2009:2024", "3.5 GB",
      "one row per 990 filing: filer EIN, name, address"),
    c("efile_mission",     "orgtext",
      ef("F9-P03-T00-MISSION"), "csv", "FALSE", "2009:2024", NA,
      "mission statement text, EIN-keyed"),
    c("efile_related",     "ein_relation",
      ef("SR-P02-T01-ID-RLTD-TAX-EXEMPED-ORGS"), "csv", "FALSE", "2009:2024", NA,
      "Schedule R Part II: related tax-exempt organisations"),
    c("meta_names",        "name (former, in_care_of, dba)",
      meta("metadata-names"), "csv", "FALSE", NA, "393 MB",
      "historic name variants: ORG_NAME_ALL, ORG_NAME_SEC, ORG_PERS_ICO. See ?md_meta_caveats"),
    c("meta_addresses",    "address (historical, mailing)",
      meta("metadata-addresses"), "csv", "FALSE", NA, "672 MB",
      "historic address variants: ORG_ADDRESS_ALL, ORG_ADDRESS_RECENT. See ?md_meta_caveats"),
    c("meta_group_aff",    "ein_relation",
      meta("metadata-group-aff"), "csv", "FALSE", NA, "21 MB",
      "group affiliation inclusion flag, per EIN"),
    c("meta_group_number", "entity.group_exemption_number, ein_relation",
      meta("metadata-group-number"), "csv", "FALSE", NA, "20 MB",
      "GEN (group exemption number) per EIN - the join key for subordinates"),
    c("meta_group_return", "ein_relation",
      meta("metadata-group-return"), "csv", "FALSE", NA, "42 MB",
      "group-return filing flag, per EIN"),
    c("irs527",            "entity (irs527), name, address, orgtext",
      "https://nccsdata.s3.us-east-1.amazonaws.com/public/pacs/2024-11-POL-ORGS-FM-8871.csv",
      "csv", "FALSE", NA, "37 MB",
      "IRS Form 8871. 68,365 filings / 51,542 EINs; key is FORM_ID_NUMBER, not EIN. See ?md_irs527_shape"),
    c("irs527_related",    "ein_relation (ein_b unresolved)",
      "https://nccsdata.s3.us-east-1.amazonaws.com/public/pacs/2024-11-POL-ORGS-SCHED-R.csv",
      "csv", "FALSE", NA, "12 MB",
      "527 Schedule R. 62,153 rows / 8,377 EINs. Related entity has a name, not an EIN. See ?md_irs527_shape")
  )
  out <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(out) <- c("source", "feeds", "url", "format", "pointer", "years", "size", "note")
  out$pointer <- as.logical(out$pointer)
  out
}

# NCCS metadata crosswalks. Static keys, not pointers - dated 2023-09 (group)
# and 2024-05/07 (names, addresses).
.md_nccs_meta <- "https://nccsdata.s3.dualstack.us-east-1.amazonaws.com/meta/"

#' Known hazards in the NCCS metadata name and address files
#'
#' Two things about `meta_names` / `meta_addresses` have to be settled before
#' either is trusted as a variant source, and both are visible in the first rows
#' of the files:
#'
#' \enumerate{
#'   \item **`ORG_NAME_ALL` is comma-concatenated and appears truncated.** The
#'     first data row reads
#'     `"SECOND BAPTIST CHURCH, PALMER SECOND BAPTIST CHURCH, PALMER SECOND BAPTIST CHU"` -
#'     several names joined by commas, with the last one cut mid-word. Splitting
#'     on the comma is ambiguous because organisation names contain commas, and a
#'     truncated tail would enter the database as a name that never existed.
#'     Quantify the truncation rate before ingesting; a variant source that
#'     invents strings is worse than no variant source.
#'   \item **`EIN2` is not an EIN.** It is formatted `EIN-00-0019818`; ingest must
#'     strip to nine digits and verify, not assume.
#' }
#'
#' `ORG_ADDRESS_ALL` is likewise comma-joined as `street,city,state,zip`, which
#' collides with commas inside street lines.
#'
#' @name md_meta_caveats
NULL

# e-file release currently published. Bump deliberately: a new release is a new
# set of pinned source versions, not an in-place update. v2_2 carries tax years
# through 2024; the v2_0 DuckDB build stopped at 2023.
.md_efile_base <- "https://nccs-efile.s3.us-east-1.amazonaws.com/public/efile_v2_2/"

#' URLs for a year-partitioned source
#'
#' @param source A `source` value from [md_sources()] whose `years` is set.
#' @param years Integer years, defaulting to the source's full published range.
#' @return A named character vector of URLs, named by year.
#' @export
md_source_urls <- function(source, years = NULL) {
  reg <- md_sources()
  row <- reg[reg$source == source, ]
  if (!nrow(row)) stop("unknown source: ", source)
  if (is.na(row$years)) stop(source, " is not year-partitioned")
  if (is.null(years)) years <- eval(parse(text = row$years))
  stats::setNames(sprintf(row$url, years), years)
}

#' Read upstream object metadata without downloading it
#'
#' An HTTP `HEAD`. Used to resolve a `latest/` pointer to something citable and
#' to detect that an upstream object has been replaced since it was pinned.
#'
#' @param url The object URL.
#' @return A named character vector with `etag`, `last_modified`, `size` and
#'   `status`, or `NULL` if the request failed.
#' @export
md_source_head <- function(url) {
  out <- tryCatch(
    system2("curl", c("-sI", "--max-time", "60", shQuote(url)), stdout = TRUE, stderr = FALSE),
    error = function(e) character()
  )
  if (!length(out)) return(NULL)

  field <- function(name) {
    hit <- grep(paste0("^", name, ":"), out, ignore.case = TRUE, value = TRUE)
    if (!length(hit)) return(NA_character_)
    trimws(sub("^[^:]+:", "", hit[length(hit)]))
  }
  status <- grep("^HTTP/", out, value = TRUE)
  c(
    status        = if (length(status)) trimws(sub("^HTTP/[0-9.]+ ", "", status[length(status)])) else NA_character_,
    etag          = gsub('"', "", field("ETag")),
    last_modified = field("Last-Modified"),
    size          = field("Content-Length")
  )
}

#' Pin a source to a concrete, immutable version
#'
#' Records what was fetched, from where, and when, into
#' `sources/<source>/<version>/PIN.dcf`. The pin carries the upstream `ETag`,
#' `Last-Modified` and byte count, plus the md5 of the local copy and the
#' `npmatch` normalizer signature current at pin time.
#'
#' The point is not ceremony. `md_ingest_*()` refuses to read a source directory
#' with no pin, so no row can enter the database whose origin cannot be named.
#'
#' @param source A `source` value from [md_sources()].
#' @param version Version directory name, e.g. `"v2026-08-11"`. Defaults to the
#'   upstream `Last-Modified` date, which is the honest choice for a pointer.
#' @param file Path to the already-downloaded local copy.
#' @return The pin, invisibly, as a named list.
#' @export
md_source_pin <- function(source, file, version = NULL) {
  reg <- md_sources()
  if (!source %in% reg$source) stop("unknown source: ", source)
  if (!file.exists(file)) stop("no such file: ", file)
  row <- reg[reg$source == source, ]

  head <- md_source_head(row$url)
  if (is.null(version)) {
    lm <- if (!is.null(head)) head[["last_modified"]] else NA_character_
    version <- if (!is.na(lm)) {
      format(as.Date(strptime(lm, "%a, %d %b %Y", tz = "GMT")), "v%Y-%m-%d")
    } else {
      format(Sys.Date(), "v%Y-%m-%d")
    }
  }

  pin <- list(
    source            = source,
    version           = version,
    url               = row$url,
    fetched           = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    upstream_etag     = if (!is.null(head)) head[["etag"]] else NA_character_,
    upstream_modified = if (!is.null(head)) head[["last_modified"]] else NA_character_,
    upstream_size     = if (!is.null(head)) head[["size"]] else NA_character_,
    local_file        = basename(file),
    local_size        = as.character(file.info(file)$size),
    local_md5         = unname(tools::md5sum(file)),
    npmatch_version   = as.character(utils::packageVersion("npmatch")),
    normalize_signature = npmatch::np_normalize_signature()
  )

  dest <- md_path("sources", source, version, create = TRUE)

  # A pin describes the file beside it. Writing one into a directory the file
  # does not live in produces a provenance record pointing at nothing - the pin
  # stores only a basename, so the mismatch is silent and survives until someone
  # tries to trace a row back to its source.
  same_dir <- normalizePath(dirname(file), winslash = "/", mustWork = FALSE) ==
              normalizePath(dest,          winslash = "/", mustWork = FALSE)
  if (!same_dir) {
    stop("pin/file mismatch: ", source, " pins into\n  ", dest,
         "\nbut the file is in\n  ", dirname(file),
         "\nMove the file, or pin it under the source it belongs to.",
         call. = FALSE)
  }

  write.dcf(as.data.frame(pin, stringsAsFactors = FALSE),
            file.path(dest, "PIN.dcf"))
  invisible(pin)
}

#' @rdname md_source_pin
#' @export
md_source_read_pin <- function(source, version) {
  f <- md_path("sources", source, version, "PIN.dcf")
  if (!file.exists(f)) return(NULL)
  as.list(as.data.frame(read.dcf(f), stringsAsFactors = FALSE))
}

#' Has an upstream pointer moved since we pinned it?
#'
#' Compares the live `ETag` against a recorded pin. A `TRUE` here means the
#' upstream file was replaced - not that anything is wrong, but that a rebuild
#' would produce different data, which is exactly what a pointer hides.
#'
#' @inheritParams md_source_read_pin
#' @return `TRUE` if upstream differs, `FALSE` if it matches, `NA` if unknown.
#' @export
md_source_moved <- function(source, version) {
  pin <- md_source_read_pin(source, version)
  if (is.null(pin)) return(NA)
  head <- md_source_head(pin$url)
  if (is.null(head) || is.na(head[["etag"]]) || is.na(pin$upstream_etag)) return(NA)
  !identical(unname(head[["etag"]]), pin$upstream_etag)
}

#' What the 527 files can and cannot support
#'
#' Measured on the 2024-11 vintage, before writing any ingest against them.
#'
#' @section Form 8871 (`irs527`):
#' 68,365 rows over **51,542 distinct EINs** - so the key is `FORM_ID_NUMBER`
#' (68,365 distinct, exactly the row count), not `EIN`. Each amendment is a new
#' row, which is why the file carries name variants at all: 1,231 EINs (2.4%)
#' appear under more than one organisation name. Ingest is therefore
#' filing-level for `name`/`address` and deduplicated to EIN for `entity`.
#'
#' EIN quality is perfect - all 68,365 are already bare 9-digit strings, none
#' blank. Notably better than `meta_names`, whose `EIN2` is `EIN-00-0019818`.
#'
#' The file carries four address blocks (mailing, business, custodian, contact)
#' and two person-name fields. `CUSTODIAN_NAME` and `CONTACT_PERSON_NAME` are
#' legitimate `in_care_of` variants - an organisation genuinely written as
#' "c/o <person>" is a spelling the matcher should know. `E_MAIL_ADDRESS`
#' should not be ingested: it carries no matching signal and is personal
#' contact data with no purpose in a disambiguation reference.
#'
#' @section Schedule R (`irs527_related`):
#' 62,153 rows over 8,377 EINs - only 16% of 527s file one. Three findings
#' shape how it can be used, and two of them are restrictive:
#'
#' \enumerate{
#'   \item **The related entity has no EIN.** The file gives
#'     `(527 EIN) -> (ENTITY_NAME, address)`. `ein_relation` as specified in
#'     `PLAN.md` §4 is `(ein_a, ein_b)`; this source cannot populate `ein_b`.
#'     Resolving a name to an EIN is a matching problem, which is `npmatch`'s
#'     job, not matchdb's - so these rows land with `ein_b` NULL and the
#'     counterparty recorded by name, or they wait.
#'   \item **Most related entities are not nonprofits.** Only 1,102 of 10,597
#'     distinct `ENTITY_NAME` values match a known 8871 organisation name -
#'     about 10%. The rest are sponsoring corporations, unions and trade
#'     associations, largely outside the BMF universe entirely.
#'   \item **`ENTITY_RELATIONSHIP` is free text, not an enumeration.** 528
#'     distinct values. `Connected` (54,660) and `Affiliated` (5,801) are 97.4%
#'     of rows, with a long tail running to `Mother`, `Indirect Control` and
#'     `Common candidate-CA 33rd Assembly Dist.`. Any mapping onto the
#'     `ein_relation.relation` enum has to be explicit and has to say what it
#'     does with the tail.
#' }
#'
#' Referential integrity to the 8871 file is close but not exact: 15,095 of
#' 15,285 `FORM_ID_NUMBER` values resolve, leaving **190 orphans (1.2%)**.
#'
#' @section What must not happen:
#' The related entity's name must never be registered as a `name` variant on the
#' 527's EIN. `PLAN.md` §10 is explicit that affiliates are not DBAs, and this is
#' the case that most invites the error - "ASSOCIATION OF SAFETY GROUPS" is a
#' different body from "ASGM PAC", and aliasing them would manufacture exactly
#' the false matches the disambiguation database exists to prevent.
#'
#' @section An ingest hazard:
#' `data.table::fread()` segfaults on the 8871 file; `utils::read.csv()` reads it
#' cleanly. The data is not malformed - line count and row count agree, so there
#' are no embedded newlines. Ingest should not assume `fread` on these.
#'
#' @name md_irs527_shape
NULL

#' Why 527 Schedule B is not a matchdb source
#'
#' `2024-11-POL-ORGS-SCHED-B.csv` (1.33 GB, 6,936,571 rows) records what a 527
#' *paid out*: filer `EIN` and `ORG_NAME` on one side, `RECIEPIENT_NAME` plus an
#' address on the other, with `EXPENDITURE_AMOUNT`, `EXPENDITURE_PURPOSE` and
#' `EXPENDITURE_DATE`.
#'
#' **The recipient has no EIN.** That makes the file structurally identical to
#' 990-PF Part XIV grants - a payer identified by EIN, a payee identified only by
#' a name and address someone typed. It is therefore a *query-side* dataset: the
#' kind of file you run **against** a disambiguation database, exactly as
#' `pfmatch` runs grants against the reference. It is not a source of
#' `(name -> EIN)` observations, because the EIN on the row belongs to the payer,
#' not to the name being described.
#'
#' Ingesting it as a `name` source would attach every payee's name to the *payer's*
#' EIN - aliasing "Hawaii Republican Party" onto a teachers' union PAC. That is
#' the single most destructive thing that could be done to a disambiguation
#' reference, and the row shape makes it an easy mistake, which is why the
#' exclusion is written down rather than left implicit.
#'
#' Two further reasons it does not belong on the reference side: most payees are
#' political committees, candidates and vendors rather than exempt organisations;
#' and `RECIPIENT_OCCUPATION` and `RECIEPIENT_EMPLOYER` are individual-level
#' fields, so a large share of rows describe people, who have no place in an
#' organisational reference.
#'
#' The file is kept under `sources/query-side/` as a future matching workload.
#'
#' @name md_schedb_excluded
NULL
