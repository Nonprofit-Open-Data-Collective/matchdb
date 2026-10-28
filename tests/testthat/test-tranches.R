# Parquet tranches: a spec compiled from the files it fetched equals the same
# spec compiled from the database, and nothing less than those files will do.

tranche_remote <- function(con) {
  remote <- tempfile("remote")
  suppressMessages(md_publish_tranches(con, file.path(remote, "tranches"), commit = "abc1234"))
  list(dir = remote, url = paste0("file:///", normalizePath(remote, winslash = "/")))
}

same_compile <- function(sp, a, b) {
  x <- suppressMessages(md_compile(sp, a)); y <- suppressMessages(md_compile(sp, b))
  rownames(x$reference) <- rownames(y$reference) <- NULL
  expect_identical(y$reference, x$reference)
  for (k in c("name_freq", "token_idf", "n_name_rows")) expect_identical(y[[k]], x[[k]], label = k)
  # summed by a GROUP BY, so in no particular order on either connection
  byname <- function(v) v[order(names(v))]
  for (k in c("name_eins", "token_df")) expect_identical(byname(y[[k]]), byname(x[[k]]), label = k)
  # report tables are ordered by count, and tied rows can come either way
  rows <- function(d) if (is.null(d)) d else { d <- d[do.call(order, d), ]; rownames(d) <- NULL; d }
  expect_identical(y$report[c("rows", "stats_method")], x$report[c("rows", "stats_method")])
  expect_identical(rows(y$report$shape), rows(x$report$shape))
  expect_identical(rows(y$report$absence), rows(x$report$absence))
  expect_identical(y$stamp$db_fingerprint, x$stamp$db_fingerprint)
}

test_that("the manifest lists every file by table, layer and class, with its md5", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- tranche_remote(con)
  latest <- jsonlite::read_json(file.path(r$dir, "tranches", "latest.json"))$build
  man <- jsonlite::fromJSON(file.path(r$dir, "tranches", latest, "manifest.json"))
  expect_equal(man$build, latest)
  expect_equal(man$matchdb_commit, "abc1234")
  expect_equal(man$normalize_signature, npnormalize::np_normalize_signature())
  f <- man$files
  expect_true("name/bmf_active/observed.parquet" %in% f$path)
  expect_true("address_derived/bmf_active/historical.parquet" %in% f$path)
  expect_true("tables/stat_name_cell.parquet" %in% f$path)
  # every row of the split tables is in exactly one file
  for (t in c("name", "name_derived", "address", "address_derived")) {
    expect_equal(sum(f$rows[f$table == t]), .md_n(con, t), label = t)
  }
  for (i in seq_len(nrow(f))) {
    p <- file.path(r$dir, "tranches", latest, f$path[i])
    expect_identical(unname(tools::md5sum(p)), f$md5[i])
  }
})

test_that("a spec compiled from its fetched tranches equals one compiled from the database", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- tranche_remote(con)
  for (args in list(list(sources = "bmf"),
                    list(names = c("legal", "dba", "observed"),
                         addresses = c("mailing", "observed", "historical")),
                    list(layers = md_layers(), names = c("legal", "observed"),
                         min_corroborators = 2),
                    list(names = c("legal", "observed"), max_names = c(observed = 1)),
                    list(dba_as = "row", names = c("legal", "dba")))) {
    sp <- do.call(md_spec, args)
    local <- tempfile("local")
    suppressMessages(md_fetch_tranches(sp, remote = r$url, root = local))
    tc <- md_tranche_db(root = local)
    same_compile(sp, con, tc)
    DBI::dbDisconnect(tc, shutdown = TRUE)
  }
})

test_that("a spec fetches only its own layers and classes", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- tranche_remote(con)
  local <- tempfile("local")
  sp <- md_spec(names = c("legal", "dba"), addresses = "mailing")      # active only
  dir <- suppressMessages(md_fetch_tranches(sp, remote = r$url, root = local))
  got <- list.files(dir, recursive = TRUE)
  expect_true("name/bmf_active/observed.parquet" %in% got)   # compile decides class over all
  expect_false("name/bmf_active/in_care_of.parquet" %in% got)
  expect_false("address/bmf_active/historical.parquet" %in% got)
  expect_false(any(grepl("bmf_inactive|filer_only", got)))
  expect_true("tables/entity.parquet" %in% got)
  # a wider spec on this connection is refused, naming what is missing
  tc <- md_tranche_db(root = local); on.exit(DBI::dbDisconnect(tc, shutdown = TRUE), add = TRUE)
  wide <- md_spec(layers = c("bmf_active", "bmf_inactive"))
  expect_error(md_compile(wide, tc), "not downloaded.*bmf_inactive")
  # fetching for it adds only the difference
  m <- capture_messages(md_fetch_tranches(wide, remote = r$url, root = local))
  expect_equal(sum(grepl("^fetching", m)), 4)    # bmf_inactive's name and address files
  expect_true(any(grepl("already were", m)))
  tc2 <- md_tranche_db(root = local); on.exit(DBI::dbDisconnect(tc2, shutdown = TRUE), add = TRUE)
  same_compile(wide, con, tc2)
})

test_that("whole tables come by name, and an unknown one is an error", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- tranche_remote(con)
  local <- tempfile("local")
  dir <- suppressMessages(md_fetch_tranches(tables = "cluster", remote = r$url, root = local))
  expect_setequal(list.files(dir, recursive = TRUE),
                  c("manifest.json", "tables/cluster.parquet", "tables/entity.parquet",
                    "tables/source_vintage.parquet"))
  expect_error(md_fetch_tranches(tables = "nope", remote = r$url, root = local), "no table nope")
  tc <- md_tranche_db(root = local); on.exit(DBI::dbDisconnect(tc, shutdown = TRUE), add = TRUE)
  expect_equal(DBI::dbGetQuery(tc, "SELECT cluster_id FROM cluster")$cluster_id, "GRP-1")
})

test_that("a changed file or another normalizer's tranches are refused", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- tranche_remote(con)
  local <- tempfile("local")
  dir <- suppressMessages(md_fetch_tranches(remote = r$url, root = local))
  write("tampered", file.path(dir, "tables", "cluster.parquet"))
  expect_error(md_tranche_db(root = local), "cluster.parquet does not match")
  # a file that does not match on the remote is not kept
  build <- basename(dir)
  write("tampered", file.path(r$dir, "tranches", build, "tables", "stat_cell.parquet"))
  local2 <- tempfile("local2")
  expect_error(suppressMessages(md_fetch_tranches(remote = r$url, root = local2)),
               "stat_cell.parquet does not match")
  # another normalizer's build
  mf <- file.path(dir, "manifest.json")
  m <- jsonlite::read_json(mf); m$normalize_signature <- "v1-someotherone"
  jsonlite::write_json(m, mf, auto_unbox = TRUE, null = "null", na = "null")
  expect_error(md_tranche_db(root = local, verify = FALSE), "normalizer v1-someotherone")
})

test_that("a bundle can be published from tranches", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- tranche_remote(con)
  sp <- md_spec(names = c("legal", "observed"), addresses = c("mailing", "observed"),
                label = "from-tranches")
  local <- tempfile("local")
  suppressMessages(md_fetch_tranches(sp, remote = r$url, root = local))
  tc <- md_tranche_db(root = local); on.exit(DBI::dbDisconnect(tc, shutdown = TRUE), add = TRUE)
  a <- tempfile("pa"); b <- tempfile("pb")
  suppressMessages(md_publish(sp, a, con)); suppressMessages(md_publish(sp, b, tc))
  ra <- md_reference("from-tranches", a, build_index = FALSE)
  rb <- md_reference("from-tranches", b, build_index = FALSE)
  expect_identical(rb$reference, ra$reference)
  expect_identical(rb$clusters, ra$clusters)
})
