# md_spec() and md_compile() on a small database. The cases are the rules a
# compiled reference must keep: the pairing rule, per-class caps, sources,
# statistics that sum exactly, the row budget and the absence report.

e <- function(n) sprintf("EIN-00-%07d", n)

compile_db <- function() {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb())
  x <- function(sql) DBI::dbExecute(con, sql)
  sig <- npmatch::np_normalize_signature()
  x("CREATE TABLE entity (ein VARCHAR, layer VARCHAR, active BOOLEAN)")
  x(sprintf("INSERT INTO entity VALUES ('%s','bmf_active',TRUE), ('%s','bmf_active',TRUE),
             ('%s','bmf_inactive',FALSE), ('%s','filer_only',NULL)", e(1), e(2), e(3), e(4)))
  # names: e1 has legal (bmf + efile spelling), a dba, two observed aliases
  # whose keys differ from the legal key (ACME FDN would not: FDN normalizes
  # to FOUNDATION and joins the legal name, which is the compactor working);
  # e2 legal only; e3 inactive legal; e4 filer-only legal
  nm <- data.frame(
    name_id  = 1:10,
    ein      = e(c(1, 1, 1, 1, 1, 2, 3, 4, 1, 2)),
    name_raw = c("ACME FOUNDATION INC", "Acme Foundation, Inc.", "ACME FUND", "ACME CHARITIES",
                 "FRIENDS OF ACME", "BETA TRUST", "GAMMA CLUB", "DELTA SOCIETY",
                 "JOHN SMITH", "BETA BOOSTERS"),
    variant_class = c("legal", "legal", "dba", "observed", "observed", "legal", "legal",
                      "legal", "in_care_of", "observed"),
    source   = c("bmf", "efile990", "bmf", "schedi", "schedi", "bmf", "bmf", "efile990",
                 "bmf", "schedi"),
    source_vintage = "t", n_obs = c(NA, 3, NA, 4, 1, NA, NA, 2, NA, 1),
    n_corroborators = c(NA, NA, NA, 3, 1, NA, NA, NA, NA, 1),
    first_year = c(NA, 2015, NA, 2016, 2019, NA, NA, 2018, NA, 2020),
    last_year  = c(NA, 2022, NA, 2023, 2019, NA, NA, 2022, NA, 2020),
    stringsAsFactors = FALSE)
  DBI::dbWriteTable(con, "name", nm)
  blank <- function(n) rep("", n)
  norm <- npmatch::np_normalize(data.frame(name = nm$name_raw, dba = blank(10),
                                           division = blank(10), street = blank(10),
                                           zip5 = blank(10), zip_plus4 = blank(10), state = blank(10),
                                           stringsAsFactors = FALSE))
  DBI::dbWriteTable(con, "name_derived", data.frame(name_id = nm$name_id,
    name_key = norm$name_key, normalize_signature = sig, stringsAsFactors = FALSE))
  # addresses: e1 bmf mailing + efile mailing (same place, other spelling) +
  # a historical; the observed alias ACME FDN has its own address; e2 one mailing
  ad <- data.frame(
    address_id = 1:7,
    ein = e(c(1, 1, 1, 1, 2, 3, 4)),
    name_id = c(NA, NA, NA, 4, NA, NA, NA),
    street_raw = c("1 MAIN ST", "1 Main Street", "9 OLD RD", "5 GRANT AVE", "2 ELM ST",
                   "3 OAK ST", "4 PINE ST"),
    city_raw = c("SPRINGFIELD", "Springfield", "SPRINGFIELD", "SHELBYVILLE", "OGDEN",
                 "OGDEN", "OGDEN"),
    state = "MA", zip5 = c("01101", "01101", "01102", "01103", "01104", "01104", "01104"),
    zip_plus4 = "", county = "", variant_class = c("mailing", "mailing", "historical",
                                                   "observed", "mailing", "mailing", "mailing"),
    source = c("bmf", "efile990", "meta_address", "schedi", "bmf", "bmf", "efile990"),
    n_obs = 1L, last_vintage = c(NA, "2022", "2010", "2023", NA, NA, "2022"),
    stringsAsFactors = FALSE)
  DBI::dbWriteTable(con, "address", ad)
  an <- npmatch::np_normalize(data.frame(name = blank(7), dba = blank(7), division = blank(7),
    street = ad$street_raw, zip5 = ad$zip5, zip_plus4 = blank(7), state = ad$state,
    stringsAsFactors = FALSE))
  DBI::dbWriteTable(con, "address_derived", data.frame(address_id = ad$address_id,
    street_key = an$street_key, stringsAsFactors = FALSE))
  x("CREATE TABLE source_vintage (vintage_id VARCHAR, local_md5 VARCHAR, row_count INTEGER)")
  x("INSERT INTO source_vintage VALUES ('bmf_unified-t:entity', 'abc', 4)")
  # the derived and statistics tables, built by the real code
  suppressMessages(md_build_compact(con, what = "name"))
  suppressMessages(md_build_stats(con))
  # a group: e1 and e3 are one family across layers
  x(sprintf("CREATE TABLE cluster AS SELECT 'GRP-1' AS cluster_id, 'group_exemption' AS cluster_type"))
  x(sprintf("CREATE TABLE cluster_member AS SELECT * FROM (VALUES
             ('GRP-1', '%s'), ('GRP-1', '%s')) v(cluster_id, ein)", e(1), e(3)))
  con
}

ref_of <- function(con, ...) suppressMessages(md_compile(md_spec(...), con))

test_that("a spec is validated against the frozen vocabularies and hashed", {
  expect_error(md_spec(layers = "bmf_everything"), "unknown layers")
  expect_error(md_spec(names = c("legal", "in_care_of")), "not a name of the organisation")
  expect_error(md_spec(min_corroborators = 3), "band edge")
  expect_error(md_spec(names = "legal", max_names = c(observed = 2)), "max_names")
  a <- md_spec(names = c("dba", "legal")); b <- md_spec(names = c("legal", "dba"), label = "x")
  expect_identical(a$spec_hash, b$spec_hash)     # order and label do not change the hash
  expect_false(identical(a$spec_hash, md_spec(sources = "bmf")$spec_hash))
})

test_that("BMF-only legal + dba gives one row per EIN with the BMF spelling", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- ref_of(con, sources = "bmf")
  f <- r$reference
  expect_equal(sort(f$.ein), e(1:2))
  expect_equal(f$name[f$.ein == e(1)], "ACME FOUNDATION INC")   # not the efile spelling
  expect_equal(f$dba[f$.ein == e(1)], "ACME FUND")              # dba rides in the column
  expect_equal(f$street[f$.ein == e(1)], "1 MAIN ST")
  expect_true(all(c("name_key", "dba_key", "street_key", "name_core") %in% names(f)))
  expect_equal(f$.id, seq_len(nrow(f)))
})

test_that("observed names pair with their own address; first-party names with first-party", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- ref_of(con, names = c("legal", "observed"), addresses = c("mailing", "observed"))
  f <- r$reference[r$reference$.ein == e(1), ]
  own <- f[f$variant_class == "observed" & f$name == "ACME CHARITIES", ]
  expect_equal(own$street, "5 GRANT AVE")                       # its own address only
  bare <- f[f$variant_class == "observed" & f$name == "FRIENDS OF ACME", ]
  expect_equal(bare$street, "1 MAIN ST")                        # no own address: first-party
  expect_false(any(f$variant_class == "legal" & f$street == "5 GRANT AVE"))
  expect_equal(sum(f$variant_class == "legal"), 1)              # the two spellings are one key
})

test_that("min_corroborators and per-class caps select by the defined order", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- ref_of(con, names = c("legal", "observed"), min_corroborators = 2)
  expect_setequal(r$reference$name[r$reference$variant_class == "observed"], "ACME CHARITIES")
  r <- ref_of(con, names = c("legal", "observed"), max_names = c(observed = 1))
  obs <- r$reference[r$reference$variant_class == "observed", ]
  expect_equal(obs$name[obs$.ein == e(1)], "ACME CHARITIES")          # 3 filers beats 1
  expect_match(r$report$stats_method, "directly")
})

test_that("cell sums equal statistics computed directly from the same names", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  for (args in list(list(), list(names = c("legal", "dba", "observed")),
                    list(layers = c("bmf_active", "bmf_inactive", "filer_only"),
                         names = c("legal", "observed"), min_corroborators = 2))) {
    cells <- do.call(ref_of, c(list(con), args))
    expect_equal(cells$report$stats_method, "summed from cells")
    sp <- do.call(md_spec, args)
    DBI::dbExecute(con, "ALTER TABLE stat_cell RENAME TO stat_cell_off")
    direct <- suppressMessages(md_compile(sp, con))
    DBI::dbExecute(con, "ALTER TABLE stat_cell_off RENAME TO stat_cell")
    expect_match(direct$report$stats_method, "directly")
    expect_equal(cells$n_name_rows, direct$n_name_rows)
    expect_equal(cells$name_eins[order(names(cells$name_eins))],
                 direct$name_eins[order(names(direct$name_eins))])
    expect_equal(cells$token_df[order(names(cells$token_df))],
                 direct$token_df[order(names(direct$token_df))])
  }
})

test_that("npmatch's own statistics are returned over the emitted frame", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- ref_of(con, names = c("legal", "observed"), addresses = c("mailing", "historical"))
  expect_equal(r$name_freq, npmatch::np_name_freq(r$reference$name_key))
  expect_equal(r$token_idf, npmatch::np_token_idf(r$reference$name_key))
  # legal ACME is one name but two frame rows (two first-party places)
  k <- unique(r$reference$name_key[r$reference$name == "ACME FOUNDATION INC"])
  expect_equal(unname(r$name_freq[toupper(k)]), 2L)
  expect_equal(unname(r$name_eins[toupper(k)]), 1L)
})

test_that("the row budget errors before materialising, naming the classes", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_error(suppressMessages(md_compile(md_spec(names = c("legal", "observed")), con,
                                           max_rows = 2)), "over max_rows = 2.*observed")
})

test_that("the absence report counts family left out by the layers", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  thin <- ref_of(con)
  a <- thin$report$absence
  expect_equal(a$selected_eins_with_outside_family[a$cluster_type == "group_exemption"], 1)
  expect_equal(a$outside_family_eins[a$cluster_type == "group_exemption"], 1)
  full <- ref_of(con, layers = c("bmf_active", "bmf_inactive"))
  expect_equal(nrow(full$report$absence), 0)
})

test_that("a normalizer that did not build name_derived is refused", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "UPDATE name_derived SET normalize_signature = 'v1-other'")
  expect_error(md_compile(md_spec(), con), "does not match")
})

test_that("a DBA sharing the legal name's key still fills the dba field", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # ACME FUND and ACME FOUNDATION INC both normalize to ACME, so compaction
  # merges them; the BMF frame still carries ACME FUND as the dba
  f <- ref_of(con, sources = "bmf")$reference
  expect_equal(nrow(f[f$.ein == e(1), ]), 1)
  expect_equal(f$dba_key[f$.ein == e(1)], f$name_key[f$.ein == e(1)])
  # as rows, it is not a separate row: its key is the legal row's
  r <- ref_of(con, sources = "bmf", dba_as = "row")$reference
  expect_equal(nrow(r[r$.ein == e(1), ]), 1)
  expect_equal(r$dba[r$.ein == e(1)], "")
})
