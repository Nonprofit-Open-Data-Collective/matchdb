# Phase 6 acceptance against the LIVE published artifacts, in a scratch workspace:
#  1. each published bundle downloads and md_reference() accepts it;
#  2. tranches for two tiers download, md_tranche_db() accepts them, and the
#     tiers compiled from them are identical to the bundles;
#  3. the live database's manifest records the installed signature.
# Run with MATCHDB_DATA set to an empty scratch folder:
#
#   MATCHDB_DATA=<scratch> Rscript dev/verify/npnormalize-check.R
suppressMessages(library(matchdb))
stopifnot(nzchar(Sys.getenv("MATCHDB_DATA")))
cat("workspace:", md_data_root(), "\nremote:", md_remote(), "\n")
cat("installed: npnormalize", as.character(packageVersion("npnormalize")),
    "| npmatch", as.character(packageVersion("npmatch")),
    "| signature", npnormalize::np_normalize_signature(), "\n\n")
ok <- TRUE
mins <- function(t0) as.numeric(difftime(Sys.time(), t0, units = "mins"))

for (lab in c("active-legal", "active-observed", "unified-legal", "unified-observed")) {
  t0 <- Sys.time()
  suppressMessages(md_fetch_reference(lab))
  r <- tryCatch(md_reference(lab, build_index = FALSE), error = function(e) conditionMessage(e))
  if (is.character(r)) { ok <- FALSE; cat(sprintf("%-17s REFUSED: %s\n", lab, r)) } else
    cat(sprintf("%-17s accepted: %s rows, built %s, signature %s (%.1f min)\n", lab,
                format(nrow(r$reference), big.mark = ","), substr(r$stamp$built, 1, 10),
                r$stamp$normalize_signature, mins(t0)))
  rm(r); invisible(gc())
}

tiers <- list(
  md_spec(layers = "bmf_active", names = c("legal", "dba", "observed"),
          addresses = c("mailing", "observed"), min_corroborators = 2, label = "active-observed"),
  md_spec(layers = c("bmf_active", "bmf_inactive"), names = c("legal", "dba", "observed"),
          addresses = c("mailing", "observed"), min_corroborators = 2, label = "unified-observed"))
cat("\n")
for (sp in tiers) {
  t0 <- Sys.time()
  suppressMessages(md_fetch_tranches(sp))
  tc <- tryCatch(md_tranche_db(), error = function(e) conditionMessage(e))
  if (is.character(tc)) { ok <- FALSE; cat(sp$label, "tranches REFUSED:", tc, "\n"); next }
  r <- suppressMessages(md_compile(sp, tc)); md_db_close(tc)
  b <- md_reference(sp$label, build_index = FALSE)
  ref <- r$reference; rownames(ref) <- NULL
  same <- identical(ref, b$reference) && identical(r$name_freq, b$name_freq) &&
    identical(r$token_idf, b$token_idf)
  ok <- ok && same
  cat(sprintf("%-17s tranches accepted; compiled %s rows; identical to the bundle: %s (%.1f min)\n",
              sp$label, format(nrow(ref), big.mark = ","), same, mins(t0)))
  cat(sprintf("%-17s compile stamp: npnormalize %s, npmatch %s\n", "", r$stamp$npnormalize_version,
              r$stamp$npmatch_version))
  rm(r, b, ref); invisible(gc())
}

man <- jsonlite::fromJSON(paste0(md_remote(), "/MANIFEST.json"))
sig <- man$normalize_signature %||% NA
cat(sprintf("\nlive database manifest: built %s, signature %s -> %s\n", man$built %||% "?", sig,
            if (identical(sig, npnormalize::np_normalize_signature())) "accepted" else "NOT the installed signature"))
ok <- ok && identical(sig, npnormalize::np_normalize_signature())
cat(if (ok) "\nLIVE ARTIFACTS ACCEPTED\n" else "\nLIVE ARTIFACTS: PROBLEM\n")
quit(status = if (ok) 0 else 1)
