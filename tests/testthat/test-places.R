# dev/PLACES.md: place keys, place tables, classes and flags (?md_build_places).

skip_if_no_place_deps <- function() {
  skip_if_not_installed("duckdb")
}

# A database holding one of each kind of place. Each EIN gets a legal name,
# an address row and a derived row; helpers keep the fixture readable.
place_db <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  ent <- list(); adr <- list(); nm <- list(); id <- 0L
  add <- function(ein, name, street_key, unit = NA, zip5 = "60601", class = "mailing",
                  gen = "0000", ico = NA, city = "CHICAGO", state = "IL", lat = NA, lon = NA,
                  gtype = NA, fv = "2020", lv = "2024", layer = "bmf_active", source = "bmf") {
    id <<- id + 1L
    if (!ein %in% vapply(ent, `[[`, "", "ein")) {
      ent[[length(ent) + 1]] <<- list(ein = ein, layer = layer, group_exemption_number = gen)
      nm[[length(nm) + 1]] <<- list(ein = ein, variant_class = "legal", name_key = name)
      if (!is.na(ico)) nm[[length(nm) + 1]] <<- list(ein = ein, variant_class = "in_care_of",
                                                     name_key = ico)
    }
    adr[[length(adr) + 1]] <<- list(address_id = id, ein = ein, variant_class = class,
      source = source, city_raw = city, state = state, first_vintage = fv, last_vintage = lv,
      lat = lat, lon = lon, geocode_type = gtype, street_key = street_key,
      street_unit = unit, zip5 = zip5)
  }
  e <- function(i, block) sprintf("EIN-%02d-%07d", block, i)

  # federated: 12 chapters of one national body, one group ruling
  for (i in 1:12) add(e(i, 10), "PEO SISTERHOOD", "3700 GRAND AVE", zip5 = "50312", gen = "1234")
  # shared: a fiscal sponsor hosting 12 unrelated foundations, no suites
  for (i in 1:12) add(e(i, 11), sprintf("FAMILY FOUNDATION %s", LETTERS[i]), "501 SILVERSIDE RD",
                      zip5 = "19809")
  # building: 12 tenants, 10 of them with their own suite
  for (i in 1:12) add(e(i, 12), sprintf("TENANT ORG %s", LETTERS[i]), "100 CIVIC CTR",
                      unit = if (i <= 10) sprintf("STE %d", 100 + i) else NA, zip5 = "10001")
  # cluster: a school, its PTO and its foundation
  for (i in 1:3) add(e(i, 13), c("LINCOLN SCHOOL", "LINCOLN PTO", "LINCOLN FDN")[i],
                     "1 SCHOOL ST", zip5 = "60602")
  # cmra: a mailbox store, every suite a PMB
  for (i in 1:4) add(e(i, 14), sprintf("SMALL CLUB %s", LETTERS[i]), "9 MAIL PLZ",
                     unit = sprintf("PMB %d", 200 + i), zip5 = "60603")
  # care_of: an accountant's address, written c/o
  for (i in 1:3) add(e(i, 15), sprintf("SCHOLARSHIP FUND %s", LETTERS[i]), "C O SMITH CPA 5 OAK ST",
                     zip5 = "60604")
  # bank_trust: trusts administered by a bank, in its trust department
  for (i in 1:3) add(e(i, 16), sprintf("TRUST NO %d", i), "10 S DEARBORN", zip5 = "60603",
                     ico = "NORTHERN TRUST CO")
  # agent_churn: 2 current occupants, 10 that have moved on
  for (i in 1:2) add(e(i, 17), sprintf("CURRENT CLIENT %s", LETTERS[i]), "77 AGENT WAY", zip5 = "60605")
  for (i in 3:12) add(e(i, 17), sprintf("FORMER CLIENT %s", LETTERS[i]), "77 AGENT WAY", zip5 = "60605",
                      class = "historical", fv = "2012", lv = "2014")
  # military: two units at one APO address
  for (i in 1:2) add(e(i, 18), sprintf("UNIT FUND %s", LETTERS[i]), "PSC 802 BOX 74", zip5 = "09499",
                     city = "APO", state = "AE")
  # one building, two spellings: same rooftop, different street_key
  add(e(1, 19), "ALPHA ARTS", "127 FILMORE LN", zip5 = "60606", lat = 41.88001, lon = -87.63002,
      gtype = "PointAddress")
  add(e(2, 19), "BETA ARTS", "127 FILMORE LN", zip5 = "60606", lat = 41.88003, lon = -87.63001,
      gtype = "PointAddress")
  add(e(3, 19), "GAMMA ARTS", "127 FILLMORE LN", zip5 = "60606", lat = 41.88002, lon = -87.63003,
      gtype = "PointAddress")
  add(e(4, 19), "DELTA ARTS", "127 FILLMORE LN", zip5 = "60606", lat = 41.88004, lon = -87.63004,
      gtype = "PointAddress")
  # not places: a PO box, and grantee addresses a third party wrote
  for (i in 1:3) add(e(i, 20), sprintf("BOX HOLDER %s", LETTERS[i]), "PO BOX 7", zip5 = "60607")
  for (i in 1:3) add(e(i, 21), sprintf("GRANTEE %s", LETTERS[i]), "400 GIFT ST", zip5 = "60608",
                     class = "observed", source = "schedi")

  df <- function(l) do.call(rbind, lapply(l, as.data.frame, stringsAsFactors = FALSE))
  a <- df(adr)
  DBI::dbWriteTable(con, "entity", df(ent))
  DBI::dbWriteTable(con, "address", a[, c("address_id", "ein", "variant_class", "source", "city_raw",
                                          "state", "first_vintage", "last_vintage", "lat", "lon",
                                          "geocode_type")])
  DBI::dbWriteTable(con, "address_derived", data.frame(
    address_id = a$address_id, street_key = a$street_key, street_unit = a$street_unit,
    zip5 = a$zip5, normalize_signature = "v-test", stringsAsFactors = FALSE))
  n <- df(nm); n$name_id <- seq_len(nrow(n)); n$source <- "bmf"
  DBI::dbWriteTable(con, "name", n[, c("name_id", "ein", "variant_class", "source")])
  DBI::dbWriteTable(con, "name_derived", data.frame(name_id = n$name_id, name_key = n$name_key))
  con
}

pl <- function(con, key) DBI::dbGetQuery(con, sprintf("SELECT * FROM place WHERE place_key = '%s'", key))

test_that("npmatch's four classes come out as npmatch would label them", {
  skip_if_no_place_deps()
  con <- place_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_places(con))
  expect_equal(pl(con, "3700 GRAND AVE 50312")$place_class, "federated")
  expect_equal(pl(con, "501 SILVERSIDE RD 19809")$place_class, "shared")
  expect_equal(pl(con, "100 CIVIC CTR 10001")$place_class, "building")
  expect_equal(pl(con, "1 SCHOOL ST 60602")$place_class, "cluster")
  b <- pl(con, "100 CIVIC CTR 10001")
  expect_equal(c(b$n_eins, b$n_units, b$n_eins_with_unit), c(12, 10, 10))
  expect_equal(b$unit_coverage, round(10 / 12, 4))
  f <- pl(con, "3700 GRAND AVE 50312")
  expect_equal(c(f$top_name_share, f$share_in_largest_group), c(1, 1))
  expect_true(f$flag_group_confirmed)
})

test_that("a crowded address with suites it barely records is shared, not a building", {
  skip_if_no_place_deps()
  con <- place_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # drop 8 of the 10 suites: two suites, but only 2 of 12 tenants name one
  DBI::dbExecute(con, "UPDATE address_derived SET street_unit = NULL
                       WHERE street_unit IN ('STE 103','STE 104','STE 105','STE 106',
                                             'STE 107','STE 108','STE 109','STE 110')")
  suppressMessages(md_build_places(con))
  b <- pl(con, "100 CIVIC CTR 10001")
  expect_equal(b$n_units, 2)
  expect_equal(b$place_class, "shared")
})

test_that("the flags catch what the class cannot see", {
  skip_if_no_place_deps()
  con <- place_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_places(con))
  expect_true(pl(con, "9 MAIL PLZ 60603")$flag_cmra)
  expect_equal(pl(con, "9 MAIL PLZ 60603")$pmb_share, 1)
  expect_true(pl(con, "C O SMITH CPA 5 OAK ST 60604")$flag_care_of)
  bt <- pl(con, "10 S DEARBORN 60603")
  expect_true(bt$flag_bank_trust && bt$flag_care_of)
  expect_equal(bt$n_care_of_agents, 1)
  ch <- pl(con, "77 AGENT WAY 60605")
  expect_equal(c(ch$n_eins, ch$n_eins_ever), c(2, 12))
  expect_true(ch$flag_agent_churn)
  expect_equal(c(ch$first_year, ch$last_year), c(2012, 2024))
  expect_true(pl(con, "PSC 802 BOX 74 09499")$flag_military_or_gd)
  # an ordinary small cluster carries no flags
  expect_equal(pl(con, "1 SCHOOL ST 60602")$place_flags, "")
})

test_that("two spellings on one rooftop share a building id", {
  skip_if_no_place_deps()
  con <- place_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_places(con))
  a <- pl(con, "127 FILMORE LN 60606"); b <- pl(con, "127 FILLMORE LN 60606")
  expect_false(is.na(a$building_id))
  expect_equal(a$building_id, b$building_id)
  expect_equal(a$n_place_keys_in_building, 2)
})

test_that("PO boxes and third-party addresses are not places", {
  skip_if_no_place_deps()
  con <- place_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_places(con))
  keys <- DBI::dbGetQuery(con, "SELECT place_key FROM place")$place_key
  expect_false(any(grepl("PO BOX", keys)))
  expect_false("400 GIFT ST 60608" %in% keys)
})

test_that("place_layer sums to n_eins and place_unit holds only shared suites", {
  skip_if_no_place_deps()
  con <- place_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "UPDATE entity SET layer = 'bmf_inactive' WHERE ein = 'EIN-10-0000001'")
  # two chapters write the same suite
  DBI::dbExecute(con, "UPDATE address_derived SET street_unit = 'STE 9'
                       WHERE address_id IN (SELECT address_id FROM address
                                            WHERE ein IN ('EIN-10-0000002', 'EIN-10-0000003'))")
  suppressMessages(md_build_places(con))
  s <- DBI::dbGetQuery(con, "
    SELECT p.place_key, p.n_eins, sum(l.n_eins) AS by_layer
    FROM place p JOIN place_layer l USING (place_key) GROUP BY 1, 2")
  expect_equal(s$by_layer, s$n_eins)
  l <- DBI::dbGetQuery(con, "SELECT layer, n_eins FROM place_layer
                             WHERE place_key = '3700 GRAND AVE 50312' ORDER BY layer")
  expect_equal(l$n_eins, c(11, 1))
  u <- DBI::dbGetQuery(con, "SELECT * FROM place_unit")
  expect_true(all(u$n_eins >= 2))
  expect_true("9" %in% u$unit_id)
})

test_that("the place key and suite id agree in R and SQL", {
  skip_if_no_place_deps()
  sk <- c("123 MAIN ST", "PO BOX 12", "P O BOX 7", "BOX 9", "POB 3", "", NA, "1 WATERFOWL WAY")
  z <- c("60601", "60601", NA, "1", "2", "3", "4", "38120")
  u <- c("STE 300", "# 300", "STE D-2", "FL 2", "PMB 214", NA, "", "RM 216")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  .md_place_macros(con)
  DBI::dbWriteTable(con, "p", data.frame(i = seq_along(sk), sk = sk, z = z, u = u))
  got <- DBI::dbGetQuery(con, "SELECT md_place_key(sk, z) AS k, md_unit_id(u) AS id FROM p ORDER BY i")
  expect_identical(got$k, md_place_key(sk, z))
  expect_identical(got$id, md_unit_id(u))
  expect_equal(md_place_key(sk, z)[1:5], c("123 MAIN ST 60601", "", "", "", ""))
  expect_equal(md_unit_id(u)[1:5], c("300", "300", "D2", "2", "214"))
})

test_that("the place key and suite id equal npmatch's own functions", {
  skip_if_not_installed("npmatch")
  ns <- asNamespace("npmatch")
  skip_if_not(exists(".np_addr_key", envir = ns) && exists(".np_unit_id", envir = ns),
              "installed npmatch predates fix/address-class")
  sk <- c("123 MAIN ST", "PO BOX 12", "P O BOX 7", "", NA, "1 WATERFOWL WAY")
  z <- c("60601", "60601", NA, "3", "4", "38120")
  u <- c("STE 300", "# 300", "STE D-2", "FL 2", NA, "PMB 214")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  .md_place_macros(con)
  DBI::dbWriteTable(con, "p", data.frame(i = seq_along(sk), sk = sk, z = z, u = u))
  got <- DBI::dbGetQuery(con, "SELECT md_place_key(sk, z) AS k, md_unit_id(u) AS id FROM p ORDER BY i")
  expect_identical(got$k, get(".np_addr_key", envir = ns)(sk, z))
  expect_identical(got$id, get(".np_unit_id", envir = ns)(u))
})
