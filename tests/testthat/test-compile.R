# md_spec() and md_compile(). The fixture, compile_db(), is in helper-compile-db.R.

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
  same <- function(a, b) identical(a[order(names(a))], b[order(names(b))])
  expect_true(same(r$name_freq, npmatch::np_name_freq(r$reference$name_key)))
  expect_true(same(r$token_idf, npmatch::np_token_idf(r$reference$name_key)))
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

test_that("the stored lists cover every column np_normalize() adds or rewrites", {
  blank <- .md_blank_frame()
  inputs <- .md_frame_inputs
  added <- c(setdiff(names(blank), inputs), "zip5")     # zip5 is rewritten
  expect_setequal(added, c(.md_derived_name_cols, .md_address_cols(),
                           .md_derived_alt_cols))
})

test_that("a frame from stored columns is identical to np_normalize()'s", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  for (args in list(list(sources = "bmf"),
                    list(names = c("legal", "dba", "observed"),
                         addresses = c("mailing", "observed", "historical")),
                    list(layers = md_layers(), names = c("legal", "observed"),
                         addresses = "observed"),          # rows with no address
                    list(dba_as = "row", names = c("legal", "dba")))) {
    sp <- do.call(md_spec, args)
    st <- suppressMessages(md_compile(sp, con, derive = "stored"))$reference
    nz <- suppressMessages(md_compile(sp, con, derive = "normalize"))$reference
    expect_identical(names(st), names(nz))
    rownames(nz) <- NULL
    expect_identical(st, nz)
  }
})

test_that("the second address line reaches the frame, and stored still equals normalize", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "ALTER TABLE address ADD COLUMN unit_raw VARCHAR")
  DBI::dbExecute(con, "UPDATE address SET unit_raw = 'STE 1102' WHERE address_id = 1")
  suppressMessages(md_build_derived(con, chunk = 4L))
  sp <- md_spec(sources = "bmf")
  st <- suppressMessages(md_compile(sp, con, derive = "stored"))$reference
  nz <- suppressMessages(md_compile(sp, con, derive = "normalize"))$reference
  rownames(nz) <- NULL
  expect_identical(st, nz)
  expect_true("STE 1102" %in% st$unit)
})

test_that("a stored value that disagrees with the normalizer is caught", {
  con <- compile_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "UPDATE name_derived SET name_full = 'TAMPERED'")
  expect_error(suppressMessages(md_compile(md_spec(), con)), "disagree with np_normalize")
  expect_no_error(suppressMessages(md_compile(md_spec(), con, check_rows = 0)))
})
