# Build MATCHDB.duckdb from scratch.
#
#   Rscript dev/build-matchdb.R            # full build into md_data_root()
#   MATCHDB_DATA=<dir> Rscript dev/build-matchdb.R
#
# Every source must already sit in sources/<source>/<version>/ under the data
# root (?md_data_root). This script pins each one, deletes any existing
# database, runs every ingest in dependency order, then builds the derived
# tables. It stops at the first error rather than producing a partial database
# that looks complete. A full build takes on the order of an hour or two;
# md_build_derived() is most of it.
#
# The versions below are the whole definition of a build. Change one here,
# not inside an ingest.

suppressMessages(pkgload::load_all(".", quiet = TRUE))
options(width = 200, warn = 1)

V <- list(
  bmf_unified       = "v2026-09-21",   # nccsdata geocoding/unified-bmf/latest, 2026-09-21
  ntee_crosswalk    = "v2026-09",      # nccsdata crosswalks/ntee-resolved, 2026-09-21
  f1023ez           = "v2014-2023",    # irs.gov irs-tege, all ten published years
  efile             = "v3_1",          # NCCS e-file v3_1, tax years 2009-2025
  address_crosswalk = "v2026-07",      # nccsdata crosswalks/address-resolved/v2026_07
  address_geocoded  = "v2024-05",      # nccsdata meta/metadata-address-geocoded.csv
  meta_group_number = "v2023-09",      # nccsdata meta/metadata-group-number.csv
  irs527_related    = "v2024-11-15",   # nccsdata public/pacs/2024-11-POL-ORGS-SCHED-R.csv
  e_postcard        = "v2026-07",      # nccsdata raw/e-postcard/2026-07-E-POSTCARD.csv
  revocations       = "v2026-07"       # nccsdata raw/revocations/2026-07-REVOCATIONS-ORGS.csv
)
EFILE_SOURCES <- c("efile_header", "schedi", "efile_related", "efile_disregarded", "efile_officers",
                   "efile_related_ptr", "efile_related_corp", "efile_orgtext",
                   "efile_affiliate_listing", "efile_sched_c_affil")

t0 <- Sys.time()
step <- function(label, expr) {
  t1 <- Sys.time()
  cat(sprintf("\n==== %s  [%s]\n", label, format(t1, "%H:%M:%S")))
  force(expr)
  cat(sprintf("==== %s done in %.1f min (%.1f min total)\n", label,
              as.numeric(difftime(Sys.time(), t1, units = "mins")),
              as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  invisible(NULL)
}
src_files <- function(source, version, pattern) {
  f <- list.files(md_path("sources", source, version), pattern = pattern, full.names = TRUE)
  if (!length(f)) stop("no ", pattern, " files for ", source, "/", version, call. = FALSE)
  sort(f)
}

cat("data root:", md_data_root(), "\n")
cat("npmatch", as.character(utils::packageVersion("npmatch")),
    "signature", npmatch::np_normalize_signature(), "\n")

## ---- pin every source --------------------------------------------------------
step("pin sources", {
  md_source_pin("bmf_unified",
                src_files("bmf_unified", V$bmf_unified, "[.]parquet$"), V$bmf_unified)
  md_source_pin("ntee_crosswalk",
                src_files("ntee_crosswalk", V$ntee_crosswalk, "[.]csv$"), V$ntee_crosswalk)
  md_source_pin("f1023ez", src_files("f1023ez", V$f1023ez, "[.]xlsx$"), V$f1023ez)
  md_source_pin("address_crosswalk",
                src_files("address_crosswalk", V$address_crosswalk, "[.]csv$"),
                V$address_crosswalk)
  md_source_pin("address_geocoded",
                src_files("address_geocoded", V$address_geocoded, "[.]csv$"),
                V$address_geocoded)
  md_source_pin("meta_group_number",
                src_files("meta_group_number", V$meta_group_number, "[.]csv$"),
                V$meta_group_number)
  md_source_pin("irs527_related",
                src_files("irs527_related", V$irs527_related, "[.]csv$"), V$irs527_related)
  md_source_pin("e_postcard",
                src_files("e_postcard", V$e_postcard, "E-POSTCARD[.]csv$"), V$e_postcard)
  md_source_pin("revocations",
                src_files("revocations", V$revocations, "REVOCATIONS-ORGS[.]csv$"), V$revocations)
  for (s in EFILE_SOURCES) {
    md_source_pin(s, src_files(s, V$efile, "[0-9]{4}[.]CSV$"), V$efile)
  }
})

## ---- a fresh database -----------------------------------------------------------
db <- md_path("db", "MATCHDB.duckdb")
if (file.exists(db)) {
  cat("removing existing", db, "\n")
  stopifnot(unlink(db) == 0, unlink(paste0(db, ".wal")) == 0)
}
con <- md_db()
on.exit(md_db_close(con), add = TRUE)

## ---- ingests, in dependency order ----------------------------------------------
# BMF first: it defines `entity`, and every later source is matched against it.
step("BMF", md_ingest_bmf(V$bmf_unified, con = con))
step("NTEE", md_ingest_ntee(V$bmf_unified, con = con,
                            crosswalk_version = V$ntee_crosswalk))
step("1023-EZ", md_ingest_f1023ez(V$f1023ez, con = con))
# Filing headers before the observed-name sources: the guards compare a written
# name with the EIN's own first-party names, which come from BMF and headers.
step("e-file headers", md_ingest_efile_header(V$efile, con = con))
step("Schedule I", md_ingest_schedi(V$efile, con = con))
step("address crosswalk", md_ingest_address_crosswalk(con = con,
                                                      version = V$address_crosswalk))
step("Schedule R Part II + BMF group exemption",
     md_ingest_relations(V$efile, con = con))
step("Schedule R names", md_ingest_schedr(V$efile, con = con))
step("group metadata", md_ingest_group_meta(con = con, version = V$meta_group_number))
step("e-file group exemption numbers", md_ingest_efile_group(con = con, version = V$efile))
step("527 Schedule R", md_ingest_irs527_related(con = con, version = V$irs527_related))
step("Schedule R Parts I, III, IV", md_ingest_schedr_parts(con = con, version = V$efile))
step("affiliate listing", md_ingest_affiliate_listing(con = con, version = V$efile))
step("Schedule C affiliated groups", md_ingest_sched_c_affil(con = con, version = V$efile))
# After every e-file entity source, so an EIN on a 990 is filer_only, not
# postcard_only; revocations last, so revoked_only means on no other list.
step("990-N e-Postcard", md_ingest_e_postcard(V$e_postcard, con = con))
step("automatic revocations", md_ingest_revocations(V$revocations, con = con))
step("Part VII officer keys", md_ingest_officers(V$efile, con = con))
step("mission and program text", md_ingest_orgtext(V$efile, con = con))
# Geography last among ingests, so it attaches to every address loaded above.
step("census geography", md_ingest_geocode(con = con, version = V$address_geocoded))
# Websites after 1023-EZ, whose converted CSVs it reads, and after every
# entity source, since a website is kept only for a known EIN.
step("websites", md_ingest_websites(con = con, efile_version = V$efile,
                                    f1023ez_version = V$f1023ez,
                                    e_postcard_version = V$e_postcard))

## ---- derived tables --------------------------------------------------------------
step("derived columns", md_build_derived(con = con))
step("compact tables", md_build_compact(con = con))
step("groups", md_build_groups(con = con))
# After compaction and websites, which they read.
step("identifier keys", md_build_ein_key(con = con))
step("clusters", md_build_clusters(con = con))
step("statistics cells", md_build_stats(con = con))

## ---- summary ----------------------------------------------------------------------
cat("\n==== table row counts\n")
tabs <- DBI::dbListTables(con)
print(data.frame(table = tabs,
                 rows = vapply(tabs, function(t) .md_n(con, t), numeric(1)),
                 row.names = NULL))
cat("\n==== source_vintage\n")
print(DBI::dbGetQuery(con, "SELECT source, version, table_name, row_count,
                                   content_vintage, content_vintage_rule
                            FROM source_vintage ORDER BY source, table_name"))
DBI::dbExecute(con, "CHECKPOINT")
cat(sprintf("\nbuilt %s (%.2f GB) in %.1f min\n", db, file.size(db) / 1e9,
            as.numeric(difftime(Sys.time(), t0, units = "mins"))))
