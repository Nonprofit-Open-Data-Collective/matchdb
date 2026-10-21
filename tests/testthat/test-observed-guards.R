# Guards on observed (third-party) names: each flag on a fixture small enough to
# read, run through the real Schedule I ingest.

test_that("placeholder EINs", {
  expect_equal(md_placeholder_ein(c("000000000", "0", "999999999", "123456789",
                                    "EIN-00-0019818", "12-3456780", "EIN-53-0196605")),
               c(TRUE, TRUE, TRUE, TRUE, TRUE, FALSE, FALSE))
  expect_true(is.na(md_placeholder_ein(NA)))
})

test_that("placeholder names come from npmatch, and behave as the guard needs", {
  bad <- c("SEE SCHEDULE O", "See attached", "VARIOUS", "N/A", "NA", "NONE",
           "SAME AS ABOVE", "Unknown", "100", "", "  ")
  ok  <- c("UNITED WAY", "NAACP", "SEE THE WORLD FOUNDATION", "X GAMES FUND",
           "SAME DAY SURGERY CENTER", "NONE BUT THE BRAVE INC", "AA",
           # real organisations a two-letters-in-a-row rule flagged
           "1N10 INC", "S H A R E INC", "18 CORP")
  expect_true(all(npmatch::np_name_placeholder(bad)))
  expect_false(any(npmatch::np_name_placeholder(ok)))
})

test_that("apostrophes do not split words", {
  expect_equal(md_guard_key(c("ST MARY'S CARE", "St Mary\u2019s Care", "ST MARYS CARE")),
               rep("SAINT MARYS CARE", 3))
})

test_that("abbreviation rules", {
  k <- md_guard_key(c("Alpha Hosp Fdn", "AHF", "Presbyterian Church (U.S.A.)", "PCU"))
  expect_equal(k[1], "ALPHA HOSPITAL FOUNDATION")
  expect_true(md_name_pair_hit(k[2], k[1]))
  expect_true(md_name_pair_hit(k[4], k[3]))
  expect_false(md_name_pair_hit("DELTA YOUTH SOCCER", "BETA FUND"))
})

test_that("the SQL key and placeholder-EIN rules agree with the R ones", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  matchdb:::.md_guard_macros(con)
  x <- c("The Alpha Hosp. Fdn, Inc.", "A & B Svcs", "SEE SCHEDULE O", "N/A", "100",
         "St. Mary's Church", "St Mary\u2019s", "SAME AS ABOVE", "Habitat for Humanity",
         "1N10 INC", "S H A R E INC", "P33")
  DBI::dbWriteTable(con, "x", data.frame(s = x))
  got <- DBI::dbGetQuery(con, "SELECT s, md_guard_key(s) AS k FROM x")
  expect_equal(got$k[match(x, got$s)], md_guard_key(x))
  e <- c("EIN-00-0000000", "EIN-12-3456789", "EIN-00-0019818", "EIN-53-0196605")
  DBI::dbWriteTable(con, "e", data.frame(e = e))
  got <- DBI::dbGetQuery(con, "SELECT e, md_placeholder_ein(e) AS p FROM e")
  expect_equal(got$p[match(e, got$e)], md_placeholder_ein(e))
})

## ---- end to end through md_ingest_schedi() -------------------------------------

E <- list(alpha = "EIN-11-1111112", beta = "EIN-22-2222223", central = "EIN-33-3333334",
          tides = "EIN-44-4444445", solo = "EIN-55-5555556", nonames = "EIN-66-6666667",
          f2 = "EIN-77-7777778", f3 = "EIN-88-8888889")

guard_fixture_db <- function(con) {
  ent <- data.frame(ein = unlist(E)[-6], layer = "bmf_active", active = TRUE,
                    source_vintage = "bmf-test",
                    affiliation_code = c("3", "3", "6", "3", "3", "3", "3"))
  DBI::dbWriteTable(con, "entity", ent)
  # first-party names, shaped like md_ingest_bmf()'s table (no first_year/last_year)
  nm <- data.frame(
    name_id = 1:8,
    ein = c(E$alpha, E$beta, E$central, E$tides, E$solo, E$f2, E$f3, E$f3),
    name_raw = c("ALPHA HOSPITAL FOUNDATION", "BETA FUND", "PRESBYTERIAN CHURCH USA",
                 "TIDES CENTER", "SOLO ARTS COLLECTIVE", "SECOND FUNDER", "THIRD FUNDER", "P33"),
    variant_class = c(rep("legal", 7), "dba"), source = "bmf", source_vintage = "bmf-test",
    n_obs = NA_integer_, n_corroborators = NA_integer_)
  DBI::dbWriteTable(con, "name", nm)
  DBI::dbExecute(con, "CREATE TABLE address (address_id BIGINT, ein VARCHAR, name_id BIGINT,
    street_raw VARCHAR, city_raw VARCHAR, state VARCHAR, zip5 VARCHAR, variant_class VARCHAR,
    spell_rank INTEGER, source VARCHAR, source_vintage VARCHAR, n_obs INTEGER,
    first_vintage VARCHAR, last_vintage VARCHAR)")
}

# filer, recipient EIN as written, recipient name as written
guard_fixture_rows <- function() {
  r <- function(filer, ein, name) data.frame(filer = filer, ein = ein, name = name)
  d <- gsub("[^0-9]", "", unlist(E))
  rbind(
    r(E$beta, d[["alpha"]], "Alpha Hosp Fdn"),                     # consistent
    r(E$beta, d[["alpha"]], "AHF"),                                # acronym: consistent
    r(E$beta, "0", "GAMMA CLUB"),                                  # placeholder EIN
    r(E$beta, d[["alpha"]], "SEE SCHEDULE O"),                     # placeholder name
    r(E$beta, d[["beta"]], "DELTA YOUTH SOCCER LEAGUE"),           # own EIN
    r(E$beta, d[["beta"]], "BETA FUND"),                           # own EIN, own name: fine
    r(E$beta, d[["central"]], "FIRST PRESBYTERIAN CHURCH OF PATERSON"), # central
    r(E$f2,   d[["central"]], "FIRST PRESBYTERIAN CHURCH OF PATERSON"),
    r(E$beta, d[["central"]], "PRESBYTERIAN CHURCH USA"),          # the central itself
    r(E$beta, d[["central"]], "PCU"),                              # its acronym
    # Tides: five unrelated projects by two filers, plus its own name
    r(E$beta, d[["tides"]], "RIVER WATCH PROJECT"),
    r(E$beta, d[["tides"]], "OAKLAND POETRY SLAM"),
    r(E$f2,   d[["tides"]], "MIGRANT LEGAL AID NETWORK"),
    r(E$f2,   d[["tides"]], "URBAN BEEKEEPERS"),
    r(E$f3,   d[["tides"]], "DESERT SEED LIBRARY"),
    r(E$f3,   d[["tides"]], "TIDES CENTER"),
    # five unrelated names under one EIN but from one filer: not a sponsor
    r(E$f2, d[["solo"]], "NORTH CHOIR"), r(E$f2, d[["solo"]], "EAST BAND"),
    r(E$f2, d[["solo"]], "WEST DANCE TROUPE"), r(E$f2, d[["solo"]], "SOUTH MURALS"),
    r(E$f2, d[["solo"]], "CENTRAL FILM SERIES"),
    r(E$beta, d[["nonames"]], "SOMETHING UNHEARD OF"),             # nothing to compare
    r(E$beta, d[["beta"]], "RENAMED AFFILIATE CORP"),              # own EIN, but another
    r(E$f2,   d[["beta"]], "RENAMED AFFILIATE CORP"),              # filer agrees
    r(E$beta, d[["f3"]], "P33")                                    # odd, but its own name
  )
}

write_schedi_fixture <- function(dir, rows) {
  dir.create(dir, recursive = TRUE)
  csv <- data.frame(
    EIN2 = rows$filer, TAX_YEAR = "2020",
    SI_02_GRANT_US_ORG_EIN = rows$ein,
    SI_02_GRANT_US_ORG_NAME_L1 = rows$name, SI_02_GRANT_US_ORG_NAME_L2 = "",
    SI_02_GRANT_US_ORG_ADDR_L1 = "1 MAIN ST", SI_02_GRANT_US_ORG_ADDR_L2 = "",
    SI_02_GRANT_US_ORG_ADDR_CITY = "PATERSON", SI_02_GRANT_US_ORG_ADDR_STATE = "NJ",
    SI_02_GRANT_US_ORG_ADDR_ZIP = "07501")
  utils::write.csv(csv, file.path(dir, "SI-P02-T01-GRANTS-US-ORGS-GOVTS-2020.CSV"),
                   row.names = FALSE)
  writeLines(c("source: schedi", "url: test", "fetched: 2026-10-21"), file.path(dir, "PIN.dcf"))
}

test_that("Schedule I ingest flags each guard and keeps every row", {
  skip_if_not_installed("duckdb")
  root <- tempfile("mdroot"); dir.create(root)
  old <- Sys.getenv("MATCHDB_DATA", unset = NA); Sys.setenv(MATCHDB_DATA = root)
  on.exit({ if (is.na(old)) Sys.unsetenv("MATCHDB_DATA") else Sys.setenv(MATCHDB_DATA = old)
            unlink(root, recursive = TRUE) }, add = TRUE)
  rows <- guard_fixture_rows()
  write_schedi_fixture(md_path("sources", "schedi", "vtest"), rows)

  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  guard_fixture_db(con)
  suppressMessages(md_ingest_schedi("vtest", con = con))

  got <- DBI::dbGetQuery(con, "SELECT * FROM name WHERE source = 'schedi'")
  # every distinct (EIN, name) kept, flags or not
  expect_equal(nrow(got), nrow(unique(rows[, c("ein", "name")])))
  f <- function(nm, col) got[[col]][got$name_raw == nm]

  expect_true(f("Alpha Hosp Fdn", "name_ein_consistent"))
  expect_false(f("Alpha Hosp Fdn", "guard_any"))
  expect_true(f("AHF", "name_ein_consistent"))
  expect_true(f("GAMMA CLUB", "flag_placeholder_ein"))
  expect_equal(got$ein[got$name_raw == "GAMMA CLUB"], "EIN-00-0000000")
  expect_true(f("SEE SCHEDULE O", "flag_placeholder_name"))

  expect_equal(f("DELTA YOUTH SOCCER LEAGUE", "n_self_filers"), 1L)
  expect_true(f("DELTA YOUTH SOCCER LEAGUE", "flag_own_ein"))
  expect_false(f("BETA FUND", "flag_own_ein"))
  expect_false(f("RENAMED AFFILIATE CORP", "flag_own_ein"))
  expect_false(f("RENAMED AFFILIATE CORP", "name_ein_consistent"))
  expect_false(f("P33", "flag_placeholder_name"))

  pat <- "FIRST PRESBYTERIAN CHURCH OF PATERSON"
  expect_true(f(pat, "flag_group_central"))
  expect_equal(f(pat, "n_corroborators"), 2L)        # corroborated and still wrong
  expect_false(f("PRESBYTERIAN CHURCH USA", "flag_group_central"))
  expect_false(f("PCU", "flag_group_central"))

  proj <- c("RIVER WATCH PROJECT", "OAKLAND POETRY SLAM", "MIGRANT LEGAL AID NETWORK",
            "URBAN BEEKEEPERS", "DESERT SEED LIBRARY")
  expect_true(all(got$flag_multi_name[got$name_raw %in% proj]))
  expect_false(f("TIDES CENTER", "flag_multi_name"))
  solo <- c("NORTH CHOIR", "EAST BAND", "WEST DANCE TROUPE", "SOUTH MURALS", "CENTRAL FILM SERIES")
  expect_false(any(got$flag_multi_name[got$name_raw %in% solo]))
  expect_true(all(!got$name_ein_consistent[got$name_raw %in% solo]))
  ms <- DBI::dbGetQuery(con, "SELECT ein FROM entity WHERE multi_name_ein")$ein
  expect_equal(ms, E$tides)

  expect_true(is.na(f("SOMETHING UNHEARD OF", "name_ein_consistent")))
  expect_false(f("SOMETHING UNHEARD OF", "guard_any"))

  # re-running is idempotent
  before <- got[order(got$name_id), c("name_id", "guard_any", "name_ein_consistent")]
  suppressMessages(md_guard_observed(con))
  after <- DBI::dbGetQuery(con, "SELECT name_id, guard_any, name_ein_consistent FROM name
                                 WHERE source = 'schedi' ORDER BY name_id")
  expect_equal(after, before, ignore_attr = TRUE)
})
