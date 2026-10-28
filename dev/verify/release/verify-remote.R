# Fetch a bundle and the user database over public HTTPS, as a user would, and
# compile from what arrived. Arg: a scratch folder (emptied first).
suppressMessages(pkgload::load_all(".", quiet = TRUE))
root <- commandArgs(TRUE)[1]; stopifnot(!is.na(root))
unlink(root, recursive = TRUE); dir.create(root)
t0 <- Sys.time()
dir <- md_fetch_reference("active-observed", root = file.path(root, "publish"))
b <- md_reference("active-observed", root = file.path(root, "publish"))
cat("bundle ok:", nrow(b$reference), "rows; places", !is.null(b$places), "; addr_freq", class(b$addr_freq)[1], "\n")
db <- md_fetch_db(dest = file.path(root, "db", "MATCHDB.duckdb"))
con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
cat("db ok:", length(DBI::dbListTables(con)), "tables;",
    DBI::dbGetQuery(con, "SELECT count(*) n FROM address WHERE county IS NOT NULL")$n, "addresses with a county\n")
r <- md_compile(md_spec(layers = "bmf_active", names = c("legal", "dba"), addresses = "mailing"), con)
cat("compile from the fetched db:", nrow(r$reference), "rows\n")
DBI::dbDisconnect(con, shutdown = TRUE)
cat(sprintf("%.1f min\n", as.numeric(difftime(Sys.time(), t0, units = "mins"))))
