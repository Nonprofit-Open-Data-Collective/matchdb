#!/usr/bin/env Rscript
# Full-scale check of the parquet tranches (dev/TRANCHES.md): publish them from
# the database, fetch per tier over a file:// remote, compile from the tranche
# connection, and compare with the published bundles. Then compare md_lookup()
# and md_cluster() on all the tranches with the database.
#
#   MATCHDB_DATA=<root> Rscript dev/verify/tranche-check.R <scratch dir> [commit]
#
# The scratch dir is emptied per tier. The tranches go to <root>/tranches.
suppressMessages(devtools::load_all(".", quiet = TRUE))
a <- commandArgs(TRUE); scratch <- a[1]; stopifnot(!is.na(scratch))
commit <- if (length(a) > 1) a[2] else NA_character_
mins <- function(t0) as.numeric(difftime(Sys.time(), t0, units = "mins"))
t0 <- Sys.time()
con <- md_db(read_only = TRUE)
dir <- md_publish_tranches(con, commit = commit)
md_db_close(con)
man <- jsonlite::fromJSON(file.path(dir, "manifest.json"))
f <- man$files
cat(sprintf("build %s: %d files, %.2f GB, %s rows, %.1f min\n", man$build, nrow(f),
            sum(f$bytes) / 1e9, format(sum(f$rows), big.mark = ","), mins(t0)))
by <- aggregate(cbind(mb = bytes / 1e6, rows) ~ table, f, sum)
print(by[order(-by$mb), ], row.names = FALSE, digits = 6)

tiers <- list(
  md_spec(layers = "bmf_active", names = c("legal", "dba"), addresses = "mailing", label = "active-legal"),
  md_spec(layers = "bmf_active", names = c("legal", "dba", "observed"), addresses = c("mailing", "observed"),
          min_corroborators = 2, label = "active-observed"),
  md_spec(layers = c("bmf_active", "bmf_inactive"), names = c("legal", "dba", "observed"),
          addresses = c("mailing", "observed"), min_corroborators = 2, label = "unified-observed"))
url <- paste0("file:///", normalizePath(md_data_root(), winslash = "/"))
ok <- TRUE
for (sp in tiers) {
  local <- file.path(scratch, sp$label); unlink(local, recursive = TRUE)
  t1 <- Sys.time(); ld <- suppressMessages(md_fetch_tranches(sp, remote = url, root = local))
  got <- list.files(ld, recursive = TRUE, full.names = TRUE)
  tf <- mins(t1); t2 <- Sys.time()
  tc <- md_tranche_db(root = local)
  r <- suppressMessages(md_compile(sp, tc)); tcmp <- mins(t2)
  md_db_close(tc)
  b <- md_reference(sp$label, build_index = FALSE)
  ref <- r$reference; rownames(ref) <- NULL
  same <- c(frame = identical(ref, b$reference), name_freq = identical(r$name_freq, b$name_freq),
            token_idf = identical(r$token_idf, b$token_idf),
            fingerprint = identical(r$stamp$db_fingerprint, b$stamp$db_fingerprint))
  ok <- ok && all(same)
  cat(sprintf("\n%-17s fetched %d files, %.2f GB (%.1f min); open, verify and compile %.1f min\n",
              sp$label, length(got), sum(file.size(got)) / 1e9, tf, tcmp))
  cat(sprintf("  rows %s vs bundle %s; identical: %s\n", format(nrow(ref), big.mark = ","),
              format(nrow(b$reference), big.mark = ","),
              paste(names(same), same, sep = " ", collapse = ", ")))
}

db <- md_db(read_only = TRUE); tc <- md_tranche_db()
norm <- function(x) lapply(unclass(x), function(p) if (is.data.frame(p)) {
  if (nrow(p)) p <- p[do.call(order, p), , drop = FALSE]; rownames(p) <- NULL; p } else p)
for (ein in c("53-0196605", "39-1925617", "13-1623829")) {
  parts <- c(md_lookup_parts(), "orgtext")
  same <- identical(norm(md_lookup(ein, parts, con = db)), norm(md_lookup(ein, parts, con = tc))) &&
    identical(norm(md_cluster(ein, con = db)), norm(md_cluster(ein, con = tc)))
  ok <- ok && same
  cat(sprintf("%s: md_lookup() and md_cluster() identical %s\n", ein, same))
}
md_db_close(db); md_db_close(tc)
cat(sprintf("\n%s, %.1f min\n", if (ok) "TRANCHES MATCH" else "TRANCHES DIFFER", mins(t0)))
quit(status = if (ok) 0 else 1)
