# The workspace log: every fetch, compile and publish is a row in an
# append-only index with its own detail file; state.json says what is here now;
# a new build or another normalizer is a version_change row.

fresh_root <- function(env = parent.frame()) {
  withr::local_envvar(MATCHDB_DATA = tempfile("ws"), .local_envir = env)
  md_data_root()
}

publish_remote <- function(con) {
  remote <- tempfile("remote")
  withr::with_options(list(matchdb.log = FALSE),
                      suppressMessages(md_publish_tranches(con, file.path(remote, "tranches"))))
  list(dir = remote, url = paste0("file:///", normalizePath(remote, winslash = "/")))
}

test_that("a fetch is one index row and a detail file listing every file and the manifest", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- publish_remote(con); root <- fresh_root()
  sp <- md_spec(names = c("legal", "dba"))
  suppressMessages(md_fetch_tranches(sp, remote = r$url))
  lg <- md_log()
  expect_equal(nrow(lg), 1)
  expect_equal(lg$kind, "fetch_tranches")
  expect_equal(lg$spec_hash, sp$spec_hash)
  expect_equal(lg$normalize_signature, npnormalize::np_normalize_signature())
  expect_true(lg$downloaded > 0 && lg$reused == 0 && lg$failed == 0)
  d <- md_log_run(lg$run_id)
  expect_equal(d$status[1], "manifest")
  expect_match(d$source[1], "manifest.json$")
  expect_equal(sum(d$status == "downloaded"), lg$downloaded)
  expect_true(all(nchar(d$md5) == 32))
  # a second fetch of the same spec downloads nothing and says so
  suppressMessages(md_fetch_tranches(sp, remote = r$url))
  lg <- md_log()
  expect_equal(nrow(lg), 2)
  expect_equal(lg$downloaded[2], 0)
  expect_equal(lg$reused[2], lg$files[2])
})

test_that("a compile is logged with its spec and source, and becomes the last compile", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- publish_remote(con); fresh_root()
  sp <- md_spec(names = c("legal", "observed"), addresses = c("mailing", "observed"))
  suppressMessages(md_fetch_tranches(sp, remote = r$url))
  tc <- md_tranche_db(); on.exit(DBI::dbDisconnect(tc, shutdown = TRUE), add = TRUE)
  out <- suppressMessages(md_compile(sp, tc))
  lg <- md_log("compile")
  expect_equal(nrow(lg), 1)
  expect_match(lg$note, "^tranches ")
  det <- md_log_run(lg$run_id)
  expect_equal(det$spec$spec_hash, sp$spec_hash)
  expect_equal(det$rows, out$report$rows)
  st <- md_status()
  expect_equal(st$last_compile$spec_hash, sp$spec_hash)
  expect_equal(st$last_compile$rows, out$report$rows)
  expect_equal(st$tranches$build, lg$build)
  expect_true(st$tranches$files_here > 0)
  expect_true(file.exists(file.path(md_data_root(), "logs", "state.json")))
})

test_that("md_tranches() lists the build and what a spec still needs", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- publish_remote(con); fresh_root()
  sp <- md_spec(names = c("legal", "dba"))
  all <- md_tranches(remote = r$url)
  expect_s3_class(all, "md_tranches")
  expect_false(any(all$here))
  expect_equal(attr(all, "normalize_signature"), npnormalize::np_normalize_signature())
  need <- md_tranches(sp, remote = r$url)
  expect_true(any(need$needed) && !all(need$needed))
  expect_false(any(need$needed[need$table == "name" & need$variant_class == "in_care_of"]))
  suppressMessages(md_fetch_tranches(sp, remote = r$url))
  after <- md_tranches(sp, local = TRUE)
  expect_true(all(after$here[after$needed]))
  expect_output(print(after), "still to download: 0 files")
  m <- md_tranche_manifest(local = TRUE)
  expect_equal(m$build, attr(after, "build"))
  expect_true(all(c("path", "table", "rows", "bytes", "md5") %in% names(m$files)))
})

test_that("a new build reuses identical files, logs the change, and keeps the history", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- publish_remote(con); fresh_root()
  sp <- md_spec(names = c("legal", "observed"), addresses = c("mailing", "observed"))
  suppressMessages(md_fetch_tranches(sp, remote = r$url))
  old <- md_tranche_manifest(local = TRUE)$build
  first <- md_log()
  # a new release: one more observed name for e2
  DBI::dbExecute(con, sprintf("INSERT INTO name (name_id, ein, name_raw, variant_class, source,
                                 source_vintage, n_obs, n_corroborators, first_year, last_year)
                               VALUES (11, '%s', 'BETA TRUST BOOSTERS', 'observed', 'schedi', 't',
                                       2, 2, 2021, 2021)", e(2)))
  suppressMessages(md_build_derived(con, chunk = 4L))
  withr::with_options(list(matchdb.log = FALSE),
                      suppressMessages(md_publish_tranches(con, file.path(r$dir, "tranches"))))
  new <- md_tranche_manifest(remote = r$url)$build
  expect_false(identical(old, new))
  d <- md_tranche_diff(old, remote = r$url)
  expect_equal(d$status[d$path == "name/bmf_active/observed.parquet"], "changed")
  expect_equal(d$rows_new[d$path == "name/bmf_active/observed.parquet"] -
                 d$rows_old[d$path == "name/bmf_active/observed.parquet"], 1)
  expect_equal(d$status[d$path == "tables/entity.parquet"], "same")
  expect_output(print(d), "changed")
  suppressMessages(md_fetch_tranches(sp, remote = r$url))
  lg <- md_log()
  # the earlier rows are exactly as they were
  expect_identical(lg[seq_len(nrow(first)), ], first)
  vc <- lg[lg$kind == "version_change", ]
  expect_equal(nrow(vc), 1)
  expect_match(vc$note, sprintf("tranches %s -> %s", old, new), fixed = TRUE)
  f <- md_log_run(utils::tail(lg$run_id, 1))
  expect_equal(f$status[f$path == "tables/entity.parquet"], "copied")
  expect_equal(f$status[f$path == "name/bmf_active/observed.parquet"], "downloaded")
  expect_equal(md_status()$tranches$build, new)
  expect_equal(md_status()$tranches$other_builds, old)
  # pruning the old build frees its parquet, keeps its manifest, and is logged
  freed <- suppressMessages(md_tranches_prune(keep = 1))
  expect_gt(freed, 0)
  left <- list.files(file.path(md_path("tranches"), old), recursive = TRUE)
  expect_equal(left, "manifest.json")
  expect_equal(utils::tail(md_log(), 1)$kind, "prune")
  # the current build is untouched
  tc <- md_tranche_db(); on.exit(DBI::dbDisconnect(tc, shutdown = TRUE), add = TRUE)
  expect_no_error(suppressMessages(md_compile(sp, tc)))
})

test_that("an npmatch or normalizer change since the last action is a version_change row", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- publish_remote(con); fresh_root()
  suppressMessages(md_fetch_tranches(tables = "cluster", remote = r$url))
  # as if the last action had run under an older normalizer
  f <- file.path(md_data_root(), "logs", "state.json")
  s <- jsonlite::read_json(f); s$installed$normalize_signature <- "v1-0ldsignature0"
  jsonlite::write_json(s, f, auto_unbox = TRUE, null = "null", na = "null")
  suppressMessages(md_fetch_tranches(tables = "cluster", remote = r$url))
  lg <- md_log()
  expect_equal(lg$kind, c("fetch_tranches", "version_change", "fetch_tranches"))
  expect_match(lg$note[2], "normalize_signature v1-0ldsignature0 -> ", fixed = TRUE)
  expect_equal(md_log("version_change")$normalize_signature, npnormalize::np_normalize_signature())
})

test_that("an index written before npnormalize gains its columns, keeping the old rows", {
  fresh_root()
  dir <- file.path(md_data_root(), "logs"); dir.create(dir, recursive = TRUE)
  old <- setdiff(.md_log_cols, c("npnormalize_version", "npnormalize_commit"))
  row <- stats::setNames(as.list(rep(NA, length(old))), old)
  row[c("run_id", "kind", "recorded_at", "npmatch_version", "normalize_signature", "note")] <-
    list("r0", "fetch_db", "2026-10-26T00:00:00-0700", "0.1.1", "v1-3e7b9f9d59bbb19e", "")
  utils::write.csv(as.data.frame(row), file.path(dir, "runs-index.csv"), row.names = FALSE)
  .md_log("prune", note = "after the upgrade")
  lg <- md_log()
  expect_equal(names(lg), .md_log_cols)
  expect_equal(lg$kind, c("fetch_db", "prune"))
  expect_equal(lg$npmatch_version[1], "0.1.1")
  expect_true(is.na(lg$npnormalize_version[1]))
  expect_equal(lg$npnormalize_version[2], as.character(utils::packageVersion("npnormalize")))
  expect_equal(lg$normalize_signature, rep(npnormalize::np_normalize_signature(), 2))
})

test_that("options(matchdb.log = FALSE) writes nothing", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- publish_remote(con); fresh_root()
  withr::local_options(matchdb.log = FALSE)
  suppressMessages(md_fetch_tranches(tables = "cluster", remote = r$url))
  expect_false(dir.exists(file.path(md_data_root(), "logs")))
  expect_null(suppressMessages(md_log()))
})
