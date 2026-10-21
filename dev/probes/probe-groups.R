# What does md_build_groups() produce on the real BMF, and how much of a shared
# name do the groups explain? Builds a scratch database (BMF + the BMF group
# exemption edges) and prints the figures in REDUCTION.md section 6a.
#
#   PROBE_ROOT=<scratch dir> BMF_PARQUET=<bmf_unified parquet> Rscript dev/probes/probe-groups.R
#
# The BMF is hard-linked into the scratch root (same volume), not copied.
suppressMessages(pkgload::load_all(".", quiet = TRUE)); options(width = 200)
root <- Sys.getenv("PROBE_ROOT")
bmf  <- Sys.getenv("BMF_PARQUET", "C:/Users/jlecy/Documents/fiscal-data/PANEL/bmf/bmf_unified_geocoded.parquet")
stopifnot(nzchar(root))
Sys.setenv(MATCHDB_DATA = root)

d <- md_path("sources", "bmf_unified", "v2026-08-11", create = TRUE)
to <- file.path(d, basename(bmf)); if (!file.exists(to)) stopifnot(file.link(bmf, to))
writeLines(c("source: bmf_unified", "url: local", paste0("fetched: ", Sys.Date()),
             paste0("local_file: ", basename(bmf))), file.path(d, "PIN.dcf"))

db <- file.path(root, "groups.duckdb"); unlink(db)
con <- md_db(path = db); on.exit(md_db_close(con))
md_ingest_bmf("v2026-08-11", con = con, validate = FALSE)
md_ingest_relations(con = con)   # no Schedule R files: group exemption half only
print(system.time(out <- md_build_groups(con))); print(out)

q <- function(s) print(DBI::dbGetQuery(con, s))
q("SELECT role, count(*) n FROM entity_group GROUP BY 1 ORDER BY 1")
q("SELECT count(*) AS eins_with_2plus_parents FROM entity_group WHERE n_parents > 1")
q("SELECT g.group_id, g.group_size, g.group_central_ein, e.n AS central_name
   FROM (SELECT DISTINCT group_id, group_size, group_central_ein FROM entity_group) g
   LEFT JOIN (SELECT ein, min(name_raw) n FROM name WHERE variant_class = 'legal' GROUP BY 1) e
     ON e.ein = g.group_central_ein
   ORDER BY group_size DESC LIMIT 12")
# how much of a shared legal name falls inside groups, and in how many
q("WITH nm AS (SELECT DISTINCT ein, name_raw FROM name WHERE variant_class = 'legal'
               AND name_raw IN ('TOASTMASTERS INTERNATIONAL','KNIGHTS OF COLUMBUS','AMERICAN LEGION'))
   SELECT nm.name_raw, count(DISTINCT nm.ein) AS eins_with_name,
          count(DISTINCT g.ein) AS in_a_group, count(DISTINCT g.group_id) AS n_groups
   FROM nm LEFT JOIN entity_group g USING (ein) GROUP BY 1 ORDER BY 2 DESC")
# GEN holders the ingest gives no edge, because their GEN has no coded parent
q("SELECT count(*) AS eins_with_gen_but_no_group FROM entity e ANTI JOIN entity_group g USING (ein)
   WHERE group_exemption_number IS NOT NULL AND group_exemption_number NOT IN ('','0000')")
