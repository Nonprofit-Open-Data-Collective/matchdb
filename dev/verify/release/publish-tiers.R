# Republish the four named tiers and the parquet tranches from the database,
# under the installed normalizer. The specs are the ones every release so far
# has published (see any publish/<label>/<hash>/stamp.json).
#
#   MATCHDB_DATA=<root> Rscript dev/verify/release/publish-tiers.R
suppressMessages(pkgload::load_all(".", quiet = TRUE))
stopifnot(nzchar(Sys.getenv("MATCHDB_DATA")))
cat("data root:", md_data_root(), "| signature", npnormalize::np_normalize_signature(), "\n")
active <- "bmf_active"; unified <- c("bmf_active", "bmf_inactive")
legal <- c("legal", "dba"); observed <- c("legal", "dba", "observed")
tiers <- list(
  md_spec(layers = active, names = legal, addresses = "mailing", label = "active-legal"),
  md_spec(layers = active, names = observed, addresses = c("mailing", "observed"),
          min_corroborators = 2, label = "active-observed"),
  md_spec(layers = unified, names = legal, addresses = "mailing", label = "unified-legal"),
  md_spec(layers = unified, names = observed, addresses = c("mailing", "observed"),
          min_corroborators = 2, label = "unified-observed"))
con <- md_db(read_only = TRUE)
on.exit(md_db_close(con), add = TRUE)
for (sp in tiers) {
  t0 <- Sys.time()
  p <- md_publish(sp, con = con)
  cat(sprintf("%-18s %.1f min  files: %s\n", sp$label,
              as.numeric(difftime(Sys.time(), t0, units = "mins")),
              paste(sort(list.files(p)), collapse = " ")))
}
t0 <- Sys.time()
commit <- system2("git", c("rev-parse", "--short=7", "HEAD"), stdout = TRUE)
tr <- md_publish_tranches(con, commit = commit)
print(tr)
cat(sprintf("tranches %.1f min\n", as.numeric(difftime(Sys.time(), t0, units = "mins"))))
