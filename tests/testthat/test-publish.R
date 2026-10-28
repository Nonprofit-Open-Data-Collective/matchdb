# Publishing: a bundle reads back as the frame that was compiled, a changed file
# or a different normalizer is refused, and rollback is moving a pointer.


test_that("a published bundle reads back as the compiled frame and statistics", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  root <- tempfile("pub")
  sp <- md_spec(names = c("legal", "observed"), addresses = c("mailing", "observed"),
                label = "test-observed")
  suppressMessages(md_publish(sp, root, con))
  direct <- suppressMessages(md_compile(sp, con))
  got <- md_reference("test-observed", root, build_index = FALSE)
  ref <- direct$reference; rownames(ref) <- NULL
  expect_identical(got$reference, ref)
  expect_identical(got$name_freq, direct$name_freq)
  expect_identical(got$token_idf, direct$token_idf)
  expect_equal(got$stamp$spec_hash, sp$spec_hash)
  expect_equal(got$stamp$normalize_signature, npnormalize::np_normalize_signature())
})

test_that("a changed file or another normalizer's bundle is refused", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  root <- tempfile("pub"); sp <- md_spec(label = "t")
  dir <- suppressMessages(md_publish(sp, root, con))
  st <- jsonlite::read_json(file.path(dir, "stamp.json"))
  st$normalize_signature <- "v1-someotherone"
  jsonlite::write_json(st, file.path(dir, "stamp.json"), auto_unbox = TRUE)
  expect_error(md_reference("t", root, build_index = FALSE), "republish it")
  dir <- suppressMessages(md_publish(sp, root, con))           # a good bundle again
  write("tampered", file.path(dir, "token_idf.parquet"))
  expect_error(md_reference("t", root, build_index = FALSE), "token_idf.parquet .* md5")
})

test_that("rollback is moving latest.json back to an earlier bundle", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  root <- tempfile("pub")
  old <- md_spec(label = "tier")
  new <- md_spec(names = c("legal", "dba", "observed"), label = "tier")
  suppressMessages(md_publish(old, root, con))
  suppressMessages(md_publish(new, root, con))
  expect_equal(md_reference("tier", root, build_index = FALSE)$stamp$spec_hash, new$spec_hash)
  md_publish_pointer("tier", old$spec_hash, root)
  expect_equal(md_reference("tier", root, build_index = FALSE)$stamp$spec_hash, old$spec_hash)
  expect_error(md_publish_pointer("tier", "not-a-hash", root), "no published bundle")
})

test_that("the bundle carries the clusters touching its EINs", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "ALTER TABLE cluster ADD COLUMN size INTEGER")
  DBI::dbExecute(con, "ALTER TABLE cluster ADD COLUMN brand_tokens VARCHAR")
  DBI::dbExecute(con, "ALTER TABLE cluster_member ADD COLUMN role VARCHAR")
  root <- tempfile("pub")
  suppressMessages(md_publish(md_spec(label = "thin"), root, con))   # active only
  cl <- md_reference("thin", root, build_index = FALSE)$clusters
  expect_equal(cl$ein, "EIN-10-0000001")       # e3, inactive, is outside the bundle
  expect_equal(cl$cluster_id, "GRP-1")
})

test_that("a bundle carries address sharing over exactly its own rows", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  root <- tempfile("pub"); sp <- md_spec(label = "t-addr")
  suppressMessages(md_publish(sp, root, con))
  got <- md_reference("t-addr", root, build_index = FALSE)
  expect_s3_class(got$addr_freq, "np_addr_freq")
  expect_identical(unclass(got$addr_freq), unclass(md_addr_freq(as.data.frame(got$reference))))
  expect_true("addr_freq.parquet" %in% names(got$stamp$files))
  expect_equal(got$stamp$addr_freq$share_min, 10)
})

test_that("a bundle carries the place evidence for its own places", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_places(con))
  root <- tempfile("pub"); sp <- md_spec(label = "t-place")
  suppressMessages(md_publish(sp, root, con))
  got <- md_reference("t-place", root, build_index = FALSE)
  expect_named(got$places, c("place", "layer", "unit"))
  keys <- unique(md_place_key(got$reference$street_key, got$reference$zip5))
  expect_true(all(got$places$place$place_key %in% keys))
  expect_true(all(c("place.parquet", "place_layer.parquet", "place_unit.parquet") %in%
                  names(got$stamp$files)))
})
