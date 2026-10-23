# md_lookup(), md_cluster() and fetching published bundles, on the small
# compile database plus the tables a full build adds.

lookup_db <- function() {
  con <- compile_db()
  x <- function(sql) DBI::dbExecute(con, sql)
  x(sprintf("CREATE TABLE entity_event AS SELECT * FROM (VALUES
    ('%s', 'revoked', DATE '2019-05-15', 2019, NULL, 'revocations', 't')) v(ein, event,
     event_date, event_year, detail, source, source_vintage)", e(3)))
  x(sprintf("CREATE TABLE ein_relation AS SELECT * FROM (VALUES
    (1, '%s', '%s', 'BETA TRUST', 'related_entity', 'schedule_r_part_ii', 'efile_sched_r', 2018, 2022, 4))
    v(relation_id, ein_a, ein_b, related_name, relation, evidence, source, first_year, last_year, n_obs)",
    e(1), e(2)))
  x(sprintf("CREATE TABLE ein_key AS SELECT * FROM (VALUES
    ('%s', 'website', 'acme.org', 1, 2018, 2022, 1),
    ('%s', 'person', 'DOE JANE', 1, 2018, 2022, 2),
    ('%s', 'person', 'DOE JANE', 1, 2019, 2020, 2))
    v(ein, kind, key, n_sources, first_year, last_year, n_eins_sharing)", e(1), e(1), e(2)))
  # a second, larger cluster to exercise max_members and types
  x(sprintf("INSERT INTO cluster VALUES ('CTN-1', 'co_tenant')"))
  x(sprintf("INSERT INTO cluster_member VALUES ('CTN-1', '%s'), ('CTN-1', '%s'), ('CTN-1', '%s')",
            e(1), e(2), e(4)))
  con
}

test_that("md_lookup gathers every part for an EIN, in any EIN form", {
  con <- lookup_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  x <- md_lookup("10-0000001", con = con)
  expect_s3_class(x, "md_lookup")
  expect_setequal(names(x), c("entity", "names", "addresses", "events", "relations",
                              "clusters", "keys"))
  expect_equal(x$entity$layer, "bmf_active")
  expect_equal(x$names$variant_class[1], "legal")          # legal first
  expect_true("JOHN SMITH" %in% x$names$name_raw)          # in-care-of kept, labelled
  expect_true(all(nzchar(x$names$name_key[x$names$variant_class == "legal"])))
  expect_equal(x$addresses$observed_as[x$addresses$variant_class == "observed"], "ACME CHARITIES")
  expect_equal(x$relations$other_ein, e(2))
  expect_equal(x$relations$direction, "discloses")
  expect_setequal(x$clusters$cluster_id, c("GRP-1", "CTN-1"))
  expect_equal(nrow(x$events), 0)
  expect_output(print(x), "EIN-10-0000001  ACME FOUNDATION INC")
})

test_that("relations are found from either side; events are dated", {
  con <- lookup_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  x <- md_lookup(c(e(2), e(3)), con = con)
  expect_equal(x$relations$direction, "disclosed_by")
  expect_equal(x$relations$other_ein, e(1))
  expect_equal(x$events$event, "revoked")
  expect_equal(as.character(x$events$event_date), "2019-05-15")
})

test_that("officer keys are left out unless asked for", {
  con <- lookup_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_false("person" %in% md_lookup(e(1), con = con)$keys$kind)
  expect_true("person" %in% md_lookup(e(1), include_people = TRUE, con = con)$keys$kind)
  expect_error(md_lookup(e(1), parts = "everything", con = con), "unknown part")
})

test_that("md_cluster lists an EIN's families and their members with names", {
  con <- lookup_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cl <- md_cluster(e(1), con = con)
  expect_s3_class(cl, "md_cluster")
  expect_equal(cl$clusters$cluster_id, c("GRP-1", "CTN-1"))   # smaller first
  expect_equal(cl$clusters$size, c(2, 3))
  m <- cl$members[cl$members$cluster_id == "GRP-1", ]
  expect_setequal(m$ein, c(e(1), e(3)))
  expect_equal(m$name[m$ein == e(3)], "GAMMA CLUB")
  expect_equal(m$layer[m$ein == e(3)], "bmf_inactive")
  expect_equal(md_cluster(e(1), types = "co_tenant", con = con)$clusters$cluster_id, "CTN-1")
  capped <- md_cluster(cluster_id = "CTN-1", max_members = 2, con = con)
  expect_equal(nrow(capped$members), 2)
  expect_equal(capped$clusters$size, 3)                       # size is the full count
  expect_output(print(capped), "1 more")
  expect_error(md_cluster(con = con), "either")
})

test_that("a published bundle fetched from a remote reads back intact", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  remote <- tempfile("remote"); pub <- file.path(remote, "publish")
  sp <- md_spec(names = c("legal", "observed"), addresses = c("mailing", "observed"),
                label = "test-tier")
  suppressMessages(md_publish(sp, pub, con))
  url <- paste0("file:///", normalizePath(remote, winslash = "/"))
  local <- tempfile("local")
  dir <- suppressMessages(md_fetch_reference("test-tier", remote = url, root = local))
  expect_true(file.exists(file.path(dir, "reference.parquet")))
  a <- md_reference("test-tier", pub, build_index = FALSE)
  b <- md_reference("test-tier", local, build_index = FALSE)
  expect_identical(b$reference, a$reference)
  expect_identical(b$name_freq, a$name_freq)
  # a second fetch of an intact bundle downloads nothing
  expect_silent(md_fetch_reference("test-tier", remote = url, root = local))
  # md_reference(fetch = "missing") fetches into an empty root
  op <- options(matchdb.remote = url); on.exit(options(op), add = TRUE)
  local2 <- tempfile("local2")
  d <- suppressMessages(md_reference("test-tier", local2, build_index = FALSE, fetch = "missing"))
  expect_identical(d$reference, a$reference)
  expect_error(md_fetch_reference("nope", remote = url, root = local), "nothing is published as nope")
})

test_that("a fetched file that does not match its md5 is not kept", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  remote <- tempfile("remote"); pub <- file.path(remote, "publish")
  dir <- suppressMessages(md_publish(md_spec(label = "t"), pub, con))
  write("tampered", file.path(dir, "token_idf.parquet"))
  url <- paste0("file:///", normalizePath(remote, winslash = "/"))
  local <- tempfile("local")
  expect_error(suppressMessages(md_fetch_reference("t", remote = url, root = local)),
               "token_idf.parquet does not match")
  expect_false(any(grepl("token_idf", list.files(local, recursive = TRUE))))
})

test_that("md_fetch_db checks the database against its manifest", {
  remote <- tempfile("remote"); dir.create(remote)
  writeBin(charToRaw("not really a database"), file.path(remote, "MATCHDB.duckdb"))
  f <- file.path(remote, "MATCHDB.duckdb")
  man <- list(database = "MATCHDB.duckdb", size_bytes = file.size(f),
              md5 = unname(tools::md5sum(f)), built = "2026-10-23", matchdb_commit = "abcdef0")
  jsonlite::write_json(man, file.path(remote, "MANIFEST.json"), auto_unbox = TRUE)
  url <- paste0("file:///", normalizePath(remote, winslash = "/"))
  dest <- file.path(tempfile("db"), "MATCHDB.duckdb")
  suppressMessages(md_fetch_db(url, dest))
  expect_identical(unname(tools::md5sum(dest)), man$md5)
  expect_message(md_fetch_db(url, dest), "already this build")
  man$md5 <- "0000"; jsonlite::write_json(man, file.path(remote, "MANIFEST.json"), auto_unbox = TRUE)
  expect_error(suppressMessages(md_fetch_db(url, dest, overwrite = TRUE)), "md5")
})
