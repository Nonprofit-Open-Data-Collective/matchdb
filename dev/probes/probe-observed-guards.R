# How many Schedule I / Schedule R observed names does each guard flag, and how
# corroborated are they? Builds a scratch database (BMF, return headers,
# Schedule I, Schedule R) from local copies, runs md_guard_observed(), and prints
# the tables in dev/OBSERVED-NAME-GUARDS.md.
#
#   PROBE_ROOT=<scratch dir> EFILE_DIR=<dir with SI/SR/header CSVs> BMF_PARQUET=<bmf_unified parquet> \
#     Rscript dev/probes/probe-observed-guards.R
#
# Source files are hard-linked into the scratch root (same volume), not copied.
suppressMessages(pkgload::load_all(".", quiet = TRUE)); options(width = 200)
root  <- Sys.getenv("PROBE_ROOT")
efile <- Sys.getenv("EFILE_DIR", "C:/Users/jlecy/Documents/EFILE_BUILD_SEPT_2026/EFILE_V2_3")
bmf   <- Sys.getenv("BMF_PARQUET", "C:/Users/jlecy/Documents/fiscal-data/PANEL/bmf/bmf_unified_geocoded.parquet")
stopifnot(nzchar(root))
Sys.setenv(MATCHDB_DATA = root)
t0 <- Sys.time(); say <- function(...) cat(sprintf("[%5.1f min] ", as.numeric(difftime(Sys.time(), t0, units = "mins"))), ..., "\n", sep = "")

link_set <- function(source, version, files, local_file = NULL) {
  d <- md_path("sources", source, version, create = TRUE)
  for (f in files) { to <- file.path(d, basename(f)); if (!file.exists(to)) stopifnot(file.link(f, to)) }
  writeLines(c(paste0("source: ", source), "url: local", paste0("fetched: ", format(Sys.Date())),
               if (!is.null(local_file)) paste0("local_file: ", local_file)), file.path(d, "PIN.dcf"))
}
yr <- function(pat) list.files(efile, pattern = pat, full.names = TRUE)
link_set("bmf_unified", "probe", bmf, local_file = basename(bmf))
link_set("efile_header", "v2_3", yr("^F9-P00-T00-HEADER-[0-9]{4}[.]CSV$"))
link_set("schedi", "v2_3", yr("^SI-P02-T01-GRANTS-US-ORGS-GOVTS-[0-9]{4}[.]CSV$"))
link_set("efile_related", "v2_3", yr("^SR-P02-T01-.*-[0-9]{4}[.]CSV$"))

db <- file.path(root, "probe.duckdb"); unlink(db)
con <- md_db(path = db); on.exit(md_db_close(con))
md_ingest_bmf("probe", con = con, validate = FALSE);            say("bmf")
md_ingest_efile_header("v2_3", con = con);                       say("headers")
md_ingest_schedi("v2_3", con = con, guard = FALSE);              say("schedule I")
md_ingest_schedr("v2_3", con = con, guard = FALSE);              say("schedule R")
md_guard_observed(con, sources = c("schedi", "schedr"));         say("guards")

q <- function(s) DBI::dbGetQuery(con, s)
band <- "CASE WHEN n_corroborators = 1 THEN '1' WHEN n_corroborators < 5 THEN '2-4'
              WHEN n_corroborators < 20 THEN '5-19' ELSE '20+' END"
guards <- c(placeholder_ein = "flag_placeholder_ein", placeholder_name = "flag_placeholder_name",
            own_ein = "flag_own_ein", group_central = "flag_group_central",
            multi_name = "flag_multi_name", any_guard = "guard_any",
            name_inconsistent = "name_ein_consistent = FALSE", no_names = "name_ein_consistent IS NULL",
            all_rows = "TRUE")
tab <- do.call(rbind, lapply(names(guards), function(g) {
  x <- q(sprintf("SELECT source, %s AS band, count(*) AS n FROM name
                  WHERE source IN ('schedi','schedr') AND %s GROUP BY ALL", band, guards[[g]]))
  if (!nrow(x)) return(NULL)
  w <- reshape(x, idvar = "source", timevar = "band", direction = "wide")
  w[is.na(w)] <- 0
  names(w) <- sub("^n[.]", "c", names(w))
  for (b in c("c1", "c2-4", "c5-19", "c20+")) if (is.null(w[[b]])) w[[b]] <- 0
  w$rows <- rowSums(w[, c("c1", "c2-4", "c5-19", "c20+")])
  w$pct_2plus <- round(100 * (w$rows - w$c1) / w$rows, 1)
  cbind(guard = g, w[, c("source", "rows", "c1", "c2-4", "c5-19", "c20+", "pct_2plus")])
}))
cat("\n== flagged rows by guard, source and n_corroborators ==\n")
print(tab[order(tab$source, match(tab$guard, names(guards))), ], row.names = FALSE)

cat("\n== overlap: rows by number of guards raised ==\n")
print(q("SELECT source, flag_placeholder_ein::INT + flag_placeholder_name::INT + flag_own_ein::INT +
                flag_group_central::INT + flag_multi_name::INT AS n_guards, count(*) AS n
         FROM name WHERE source IN ('schedi','schedr') GROUP BY ALL ORDER BY 1, 2"), row.names = FALSE)

cat("\n== what a min_corroborators = 2 spec would keep, by guard (rows) ==\n")
print(q("SELECT source,
           count(*) FILTER (WHERE n_corroborators >= 2) AS kept_all,
           count(*) FILTER (WHERE n_corroborators >= 2 AND guard_any) AS kept_flagged,
           count(*) FILTER (WHERE n_corroborators >= 2 AND name_ein_consistent = FALSE) AS kept_inconsistent
         FROM name WHERE source IN ('schedi','schedr') GROUP BY 1 ORDER BY 1"), row.names = FALSE)

for (g in c("flag_placeholder_ein", "flag_placeholder_name", "flag_own_ein", "flag_group_central", "flag_multi_name")) {
  cat(sprintf("\n== most corroborated rows: %s ==\n", g))
  print(q(sprintf("SELECT n.source, n.ein, n.name_raw, n.n_corroborators, n.n_self_filers,
                          (SELECT any_value(l.name_raw) FROM name l WHERE l.ein = n.ein AND l.variant_class = 'legal') AS legal_name
                   FROM name n WHERE n.source IN ('schedi','schedr') AND n.%s
                   ORDER BY n.n_corroborators DESC, n.name_raw LIMIT 12", g)), row.names = FALSE)
}

cat("\n== placeholder EINs: distinct EINs and rows ==\n")
print(q("SELECT source, ein, count(*) AS names, sum(n_corroborators) AS corr FROM name
         WHERE source IN ('schedi','schedr') AND flag_placeholder_ein GROUP BY ALL ORDER BY names DESC LIMIT 12"), row.names = FALSE)

cat("\n== multi-name (fiscal-sponsor) EINs, largest ==\n")
print(q("SELECT e.ein, e.affiliation_code, count(*) AS flagged_names, sum(n.n_corroborators) AS corr,
                (SELECT any_value(l.name_raw) FROM name l WHERE l.ein = e.ein AND l.variant_class = 'legal') AS legal_name
         FROM entity e JOIN name n USING (ein)
         WHERE e.multi_name_ein AND n.flag_multi_name GROUP BY ALL ORDER BY 3 DESC LIMIT 25"), row.names = FALSE)
print(q("SELECT count(*) AS multi_name_eins, count(*) FILTER (WHERE affiliation_code IN ('6','8')) AS also_central
         FROM entity WHERE multi_name_ein"), row.names = FALSE)

cat("\n== most corroborated inconsistent names (not otherwise flagged) ==\n")
print(q("SELECT n.source, n.ein, n.name_raw, n.n_corroborators,
                (SELECT any_value(l.name_raw) FROM name l WHERE l.ein = n.ein AND l.variant_class = 'legal') AS legal_name
         FROM name n WHERE n.source IN ('schedi','schedr') AND n.name_ein_consistent = FALSE AND NOT n.guard_any
         ORDER BY n.n_corroborators DESC LIMIT 20"), row.names = FALSE)
say("done")
