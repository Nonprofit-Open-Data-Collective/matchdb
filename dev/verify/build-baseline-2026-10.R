#!/usr/bin/env Rscript
# ============================================================================
# build-baseline-2026-10.R -- re-freeze the Phase 1 baseline.
#
# The August baseline (pfmatch/dev/BASELINE-2026-08) cannot judge Phase 1 any
# more, for two reasons that have nothing to do with matchdb:
#   - it was built from the 2026-01 active BMF; the database loads the
#     2026-09-21 unified BMF (1,974,830 active EINs, not 1,924,822);
#   - npmatch's normalizer has changed since (v1-421e1e2a6afb024e ->
#     v1-b42811fe6601afe6), so run-gate.R refuses it, as it should.
#
# This rebuilds it the way pfmatch builds a reference -
# np_normalize(np_reference(bmf, map)) - from the SAME BMF file the database
# loaded, by pfmatch's own committed code (PFMATCH_CODE, a `git archive` of a
# pinned commit, so a working copy in progress elsewhere is never read).
#
# Two references, because the BMF carries two versions of each string:
#   raw        org_name_raw, dba_name_raw, org_addr_street_raw, org_addr_city_raw
#              - what matchdb stores, so the Phase 1 gate compares like with like
#   processed  org_name_join, dba_name, org_addr_street, org_addr_city
#              - what np_map_bmf() reads, i.e. pfmatch's reference today
# They differ on 37% of active names (legal-form suffix stripped), 403K DBAs
# (title case) and 325K streets (USPS abbreviations). The benchmark on each
# measures what that choice changes, separately from the gate.
#
# Writes:
#   dev/BASELINE-2026-10/        manifest.csv, environment.txt, columns-*.txt,
#                                benchmark-1k-{raw,processed}.rds (small)
#   md_data_root()/work/baseline-2026-10/REF-active-{raw,processed}.rds (large)
#
#   PFMATCH_CODE=<git archive of pfmatch>  PFMATCH_INPUTS=<dir with 1k_grants_*.csv>
#   Rscript dev/verify/build-baseline-2026-10.R
# ============================================================================
suppressWarnings(suppressMessages({
  devtools::load_all(".", quiet = TRUE)
  library(data.table)
}))
setDTthreads(0)
PFCODE <- Sys.getenv("PFMATCH_CODE"); PFIN <- Sys.getenv("PFMATCH_INPUTS")
stopifnot(nzchar(PFCODE), dir.exists(PFCODE), dir.exists(PFIN))
suppressWarnings(suppressMessages(devtools::load_all(PFCODE, quiet = TRUE)))
OUT <- file.path("dev", "BASELINE-2026-10"); dir.create(OUT, showWarnings = FALSE)
BIG <- md_path("work", "baseline-2026-10", create = TRUE)
say <- function(...) { cat(sprintf(...), "\n"); flush.console() }

BMF_VERSION <- "v2026-09-21"
pin <- md_source_read_pin("bmf_unified", BMF_VERSION)
pq <- md_path("sources", "bmf_unified", BMF_VERSION, pin$local_file)
con <- DBI::dbConnect(duckdb::duckdb())
bmf <- DBI::dbGetQuery(con, sprintf("
  SELECT EIN2, org_name_raw, dba_name_raw, org_addr_street_raw, org_addr_city_raw,
         org_name_join, dba_name, org_addr_street, org_addr_city,
         org_addr_state, org_addr_zip5, org_addr_zip4, TRUE AS active_flag
  FROM read_parquet('%s')
  WHERE last_vintage_ym = (SELECT max(last_vintage_ym) FROM read_parquet('%s'))",
  gsub("\\\\", "/", pq), gsub("\\\\", "/", pq)))
DBI::dbDisconnect(con, shutdown = TRUE)
say("BMF %s active rows: %s", BMF_VERSION, format(nrow(bmf), big.mark = ","))

maps <- list(
  raw = c(.ein = "EIN2", name = "org_name_raw", dba = "dba_name_raw",
          street = "org_addr_street_raw", city = "org_addr_city_raw",
          state = "org_addr_state", zip5 = "org_addr_zip5", zip_plus4 = "org_addr_zip4",
          active = "active_flag"),
  processed = c(.ein = "EIN2", name = "org_name_join", dba = "dba_name",
                street = "org_addr_street", city = "org_addr_city",
                state = "org_addr_state", zip5 = "org_addr_zip5", zip_plus4 = "org_addr_zip4",
                active = "active_flag"))

grants <- pf_read_grants(PFIN, pattern = "^1k_grants_.*\\.csv$")
grants <- pf_recover_name_from_street(grants, verbose = FALSE)
passes <- c(pf_staged_passes("lean", concat = TRUE), pf_recovery_passes(state = TRUE))

rows <- list()
for (which in names(maps)) {
  say("\n== %s reference", which)
  ref <- npmatch::np_normalize(npmatch::np_reference(bmf, maps[[which]]))
  bundle <- list(reference = ref, name_freq = npmatch::np_name_freq(ref$name_key),
                 token_idf = npmatch::np_token_idf(ref$name_key),
                 ref_index = npmatch::np_ref_index(ref))
  f <- file.path(BIG, sprintf("REF-active-%s.rds", which))
  saveRDS(bundle, f)
  writeLines(sort(names(ref)), file.path(OUT, sprintf("columns-reference-%s.txt", which)))
  say("  %s rows -> %s", format(nrow(ref), big.mark = ","), f)

  t0 <- proc.time()[["elapsed"]]
  m <- pf_match_grants(grants, bundle, passes = passes, recover = TRUE, verbose = FALSE)
  res <- as.data.frame(m$result)
  res <- res[order(res$.id), , drop = FALSE]; rownames(res) <- NULL
  attr(res, "pairs") <- NULL
  for (a in c("config", "profile", "stages")) attr(res, a) <- attr(m$result, a)
  bf <- file.path(OUT, sprintf("benchmark-1k-%s.rds", which))
  saveRDS(res, bf, compress = "xz")
  writeLines(sort(names(res)), file.path(OUT, sprintf("columns-tiered-%s.txt", which)))
  say("  1k benchmark in %.0f s: %s", proc.time()[["elapsed"]] - t0,
      paste(names(table(res$tier)), table(res$tier), collapse = " / "))
  rows[[which]] <- data.frame(
    artifact = c(basename(f), basename(bf)),
    role = c(sprintf("Phase 1 reference, %s BMF strings", which),
             sprintf("1k benchmark on the %s reference", which)),
    md5 = unname(tools::md5sum(c(f, bf))), rows = c(nrow(ref), nrow(res)),
    bytes = file.size(c(f, bf)), stringsAsFactors = FALSE)
  rm(ref, bundle, m, res); invisible(gc())
}
utils::write.csv(do.call(rbind, rows), file.path(OUT, "manifest.csv"), row.names = FALSE)

gitsha <- function(dir) tryCatch(substr(system2("git", c("-C", dir, "rev-parse", "HEAD"),
                                                stdout = TRUE)[1], 1, 7),
                                 error = function(e) NA_character_)
writeLines(c(
  sprintf("pfmatch          %s (git archive at %s)", basename(PFCODE), PFCODE),
  sprintf("matchdb          %s", gitsha(".")),
  sprintf("npmatch          %s", as.character(utils::packageVersion("npmatch"))),
  sprintf("normalizer sig   %s", npmatch::np_normalize_signature()),
  sprintf("BMF              bmf_unified %s, md5 %s", BMF_VERSION, pin$local_md5),
  sprintf("R                %s", R.version.string),
  sprintf("built            %s", format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))),
  file.path(OUT, "environment.txt"))
say("\nwrote %s", OUT)
