# md_spec() and md_compile() on a small database. The cases are the rules a
# compiled reference must keep: the pairing rule, per-class caps, sources,
# statistics that sum exactly, the row budget and the absence report.

e <- function(n) sprintf("EIN-10-%07d", n)

compile_db <- function() {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb())
  x <- function(sql) DBI::dbExecute(con, sql)
  sig <- npmatch::np_normalize_signature()
  x("CREATE TABLE entity (ein VARCHAR, layer VARCHAR, active BOOLEAN)")
  x(sprintf("INSERT INTO entity VALUES ('%s','bmf_active',TRUE), ('%s','bmf_active',TRUE),
             ('%s','bmf_inactive',FALSE), ('%s','filer_only',NULL)", e(1), e(2), e(3), e(4)))
  # names: e1 has legal (bmf + efile spelling), a dba, two observed aliases
  # whose keys differ from the legal key (ACME FDN would not: FDN normalizes
  # to FOUNDATION and joins the legal name, which is the compactor working);
  # e2 legal only; e3 inactive legal; e4 filer-only legal
  nm <- data.frame(
    name_id  = 1:10,
    ein      = e(c(1, 1, 1, 1, 1, 2, 3, 4, 1, 2)),
    name_raw = c("ACME FOUNDATION INC", "Acme Foundation, Inc.", "ACME FUND", "ACME CHARITIES",
                 "FRIENDS OF ACME", "BETA TRUST", "GAMMA CLUB", "DELTA SOCIETY",
                 "JOHN SMITH", "BETA BOOSTERS"),
    variant_class = c("legal", "legal", "dba", "observed", "observed", "legal", "legal",
                      "legal", "in_care_of", "observed"),
    source   = c("bmf", "efile990", "bmf", "schedi", "schedi", "bmf", "bmf", "efile990",
                 "bmf", "schedi"),
    source_vintage = "t", n_obs = c(NA, 3, NA, 4, 1, NA, NA, 2, NA, 1),
    n_corroborators = c(NA, NA, NA, 3, 1, NA, NA, NA, NA, 1),
    first_year = c(NA, 2015, NA, 2016, 2019, NA, NA, 2018, NA, 2020),
    last_year  = c(NA, 2022, NA, 2023, 2019, NA, NA, 2022, NA, 2020),
    stringsAsFactors = FALSE)
  DBI::dbWriteTable(con, "name", nm)
  # addresses: e1 bmf mailing + efile mailing (same place, other spelling) +
  # a historical; the observed alias ACME FDN has its own address; e2 one mailing
  ad <- data.frame(
    address_id = 1:7,
    ein = e(c(1, 1, 1, 1, 2, 3, 4)),
    name_id = c(NA, NA, NA, 4, NA, NA, NA),
    street_raw = c("1 MAIN ST", "1 Main Street", "9 OLD RD", "5 GRANT AVE", "2 ELM ST",
                   "3 OAK ST", "4 PINE ST"),
    city_raw = c("SPRINGFIELD", "Springfield", "SPRINGFIELD", "SHELBYVILLE", "OGDEN",
                 "OGDEN", "OGDEN"),
    state = "MA", zip5 = c("01101", "01101", "01102", "01103", "01104", "01104", "01104"),
    zip_plus4 = "", county = "", variant_class = c("mailing", "mailing", "historical",
                                                   "observed", "mailing", "mailing", "mailing"),
    source = c("bmf", "efile990", "meta_address", "schedi", "bmf", "bmf", "efile990"),
    n_obs = 1L, last_vintage = c(NA, "2022", "2010", "2023", NA, NA, "2022"),
    stringsAsFactors = FALSE)
  DBI::dbWriteTable(con, "address", ad)
  # the derived tables, by the real code: every column np_normalize() adds
  suppressMessages(md_build_derived(con, chunk = 4L))
  x("CREATE TABLE source_vintage (vintage_id VARCHAR, local_md5 VARCHAR, row_count INTEGER)")
  x("INSERT INTO source_vintage VALUES ('bmf_unified-t:entity', 'abc', 4)")
  # the derived and statistics tables, built by the real code
  suppressMessages(md_build_compact(con, what = "name"))
  suppressMessages(md_build_stats(con))
  # a group: e1 and e3 are one family across layers
  x(sprintf("CREATE TABLE cluster AS SELECT 'GRP-1' AS cluster_id, 'group_exemption' AS cluster_type"))
  x(sprintf("CREATE TABLE cluster_member AS SELECT * FROM (VALUES
             ('GRP-1', '%s'), ('GRP-1', '%s')) v(cluster_id, ein)", e(1), e(3)))
  con
}

ref_of <- function(con, ...) suppressMessages(md_compile(md_spec(...), con))
