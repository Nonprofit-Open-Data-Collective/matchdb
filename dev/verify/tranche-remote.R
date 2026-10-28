#!/usr/bin/env Rscript
# Fetch the published tranches over public HTTPS (md_remote(), no credentials),
# as a user would, and check what arrived: compile two tiers and compare them
# with the local bundles, then fetch the rest and compare lookups with the
# local database.
#
#   MATCHDB_DATA=<root> Rscript dev/verify/tranche-remote.R <scratch dir>
suppressMessages(devtools::load_all(".", quiet = TRUE))
root <- commandArgs(TRUE)[1]; stopifnot(!is.na(root))
unlink(root, recursive = TRUE); dir.create(root, recursive = TRUE)
mins <- function(t0) as.numeric(difftime(Sys.time(), t0, units = "mins"))
gb <- function() { f <- list.files(root, recursive = TRUE, full.names = TRUE); sum(file.size(f)) / 1e9 }
cat("remote:", md_remote(), "\n")
t0 <- Sys.time(); ok <- TRUE
tiers <- list(
  md_spec(layers = "bmf_active", names = c("legal", "dba", "observed"), addresses = c("mailing", "observed"),
          min_corroborators = 2, label = "active-observed"),
  md_spec(layers = c("bmf_active", "bmf_inactive"), names = c("legal", "dba", "observed"),
          addresses = c("mailing", "observed"), min_corroborators = 2, label = "unified-observed"))
for (sp in tiers) {
  before <- gb(); t1 <- Sys.time()
  m <- capture_messages(md_fetch_tranches(sp, root = root))
  cat(sprintf("\n%s: %s (%.2f GB new, %.1f min)\n", sp$label, sub("\n$", "", m[length(m)]),
              gb() - before, mins(t1)))
  t2 <- Sys.time(); tc <- md_tranche_db(root = root)
  r <- suppressMessages(md_compile(sp, tc)); md_db_close(tc)
  b <- md_reference(sp$label, build_index = FALSE)
  ref <- r$reference; rownames(ref) <- NULL
  same <- identical(ref, b$reference) && identical(r$name_freq, b$name_freq) &&
    identical(r$token_idf, b$token_idf)
  ok <- ok && same
  cat(sprintf("  open, verify, compile %.1f min: %s rows; identical to the bundle %s\n", mins(t2),
              format(nrow(ref), big.mark = ","), same))
}
before <- gb(); t1 <- Sys.time()
m <- capture_messages(md_fetch_tranches(tables = "all", root = root))
cat(sprintf("\nall: %s (%.2f GB new, %.1f min)\n", sub("\n$", "", m[length(m)]), gb() - before, mins(t1)))
db <- md_db(read_only = TRUE); tc <- md_tranche_db(root = root)
norm <- function(x) lapply(unclass(x), function(p) if (is.data.frame(p)) {
  if (nrow(p)) p <- p[do.call(order, p), , drop = FALSE]; rownames(p) <- NULL; p } else p)
for (ein in c("53-0196605", "39-1925617")) {
  parts <- c(md_lookup_parts(), "orgtext")
  same <- identical(norm(md_lookup(ein, parts, con = db)), norm(md_lookup(ein, parts, con = tc))) &&
    identical(norm(md_cluster(ein, con = db)), norm(md_cluster(ein, con = tc)))
  ok <- ok && same
  cat(sprintf("%s: md_lookup() and md_cluster() identical to the database %s\n", ein, same))
}
md_db_close(db); md_db_close(tc)
cat(sprintf("\n%s; %.2f GB fetched in all, %.1f min\n",
            if (ok) "REMOTE TRANCHES MATCH" else "REMOTE TRANCHES DIFFER", gb(), mins(t0)))
quit(status = if (ok) 0 else 1)
