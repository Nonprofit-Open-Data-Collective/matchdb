# md_build_compact() and the observed-name guards: flagged observed names (and
# the addresses written with them) are left out of the compact tables by
# default, and marked in guard_any when kept.

compact_fixture <- function(con, with_guards = TRUE) {
  nm <- data.frame(
    name_id = 1:6,
    ein = c("EIN-11-1111112", "EIN-11-1111112", "EIN-11-1111112",
            "EIN-22-2222223", "EIN-22-2222223", "EIN-22-2222223"),
    name_raw = c("ALPHA FUND", "ALPHA FUND", "GAMMA CHURCH",
                 "BETA CLUB", "BETA CLUB", "% TREASURER"),
    variant_class = c("legal", "observed", "observed", "legal", "observed", "in_care_of"),
    source = c("bmf", "schedi", "schedi", "bmf", "schedi", "bmf"),
    n_obs = c(NA, 3L, 1L, NA, 2L, NA),
    n_corroborators = c(NA, 2L, 1L, NA, 2L, NA),
    first_year = NA_integer_, last_year = NA_integer_)
  # 3: GAMMA CHURCH under ALPHA's EIN, flagged and backed by nothing else
  # 5: BETA CLUB, flagged on Schedule I but also BETA's legal name
  if (with_guards) nm$guard_any <- c(NA, FALSE, TRUE, NA, TRUE, NA)
  DBI::dbWriteTable(con, "name", nm)
  DBI::dbWriteTable(con, "name_derived",
                    data.frame(name_id = nm$name_id, name_key = toupper(nm$name_raw)))
  ad <- data.frame(
    address_id = 1:4,
    ein = c("EIN-11-1111112", "EIN-11-1111112", "EIN-22-2222223", "EIN-22-2222223"),
    name_id = c(NA, 3L, NA, 5L),
    street_raw = c("1 MAIN ST", "9 CHURCH RD", "2 OAK AVE", "2 OAK AVE"),
    city_raw = c("CHICAGO", "PATERSON", "BOSTON", "BOSTON"),
    state = c("IL", "NJ", "MA", "MA"), zip5 = c("60601", "07501", "02108", "02108"),
    source = c("bmf", "schedi", "bmf", "schedi"),
    n_obs = c(NA, 1L, NA, 2L), n_corroborators = NA_integer_,
    first_vintage = "2020", last_vintage = "2024")
  DBI::dbWriteTable(con, "address", ad)
  # address compaction reads the normalized street key (Phase 5 step 6)
  DBI::dbWriteTable(con, "address_derived",
                    data.frame(address_id = ad$address_id, street_key = toupper(ad$street_raw)))
}

with_compact <- function(code, with_guards = TRUE) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  compact_fixture(con, with_guards)
  code(con)
}

nc <- function(con) DBI::dbGetQuery(con,
  "SELECT ein, name_key, variant_class, n_contributing_rows, guard_any FROM name_compact ORDER BY 1, 2")
ac <- function(con) DBI::dbGetQuery(con,
  "SELECT ein, street_key, n_contributing_rows, guard_any FROM address_compact ORDER BY 1, 2")

test_that("flagged observed names and their addresses are dropped by default", {
  skip_if_not_installed("duckdb")
  with_compact(function(con) {
    suppressMessages(md_build_compact(con))
    n <- nc(con)
    expect_false("GAMMA CHURCH" %in% n$name_key)              # flagged, nothing else behind it
    beta <- n[n$name_key == "BETA CLUB", ]
    expect_equal(nrow(beta), 1L)                              # survives on the legal row
    expect_equal(beta$n_contributing_rows, 1L)
    expect_equal(beta$variant_class, "legal")
    alpha <- n[n$name_key == "ALPHA FUND", ]
    expect_equal(alpha$n_contributing_rows, 2L)               # unflagged observed row still merges
    expect_false(any(n$guard_any))
    a <- ac(con)
    expect_false("9 CHURCH RD" %in% a$street_key)             # written with GAMMA CHURCH
    expect_equal(a$n_contributing_rows[a$street_key == "2 OAK AVE"], 1L)
    expect_false(any(a$guard_any))
  })
})

test_that("drop_guarded = FALSE keeps every row and marks fully flagged keys", {
  skip_if_not_installed("duckdb")
  with_compact(function(con) {
    suppressMessages(md_build_compact(con, drop_guarded = FALSE))
    n <- nc(con)
    expect_true(n$guard_any[n$name_key == "GAMMA CHURCH"])
    # flagged on Schedule I, but the legal row stands behind it too
    expect_false(n$guard_any[n$name_key == "BETA CLUB"])
    expect_equal(n$n_contributing_rows[n$name_key == "BETA CLUB"], 2L)
    expect_false(n$guard_any[n$name_key == "ALPHA FUND"])
    a <- ac(con)
    expect_true(a$guard_any[a$street_key == "9 CHURCH RD"])
    expect_false(a$guard_any[a$street_key == "2 OAK AVE"])
    expect_equal(a$n_contributing_rows[a$street_key == "2 OAK AVE"], 2L)
  })
})

test_that("a database where the guards never ran loses nothing", {
  skip_if_not_installed("duckdb")
  with_compact(function(con) {
    suppressMessages(md_build_compact(con))
    n <- nc(con)
    expect_true("GAMMA CHURCH" %in% n$name_key)
    expect_false(any(n$guard_any))
    expect_true("9 CHURCH RD" %in% ac(con)$street_key)
  }, with_guards = FALSE)
})

test_that("in_care_of rows stay excluded either way", {
  skip_if_not_installed("duckdb")
  with_compact(function(con) {
    suppressMessages(md_build_compact(con, drop_guarded = FALSE))
    expect_false("% TREASURER" %in% nc(con)$name_key)
  })
})
