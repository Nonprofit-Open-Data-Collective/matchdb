# ein_key and the cluster layer, on a small synthetic database. Each case is a
# rule that, broken, would either invent a family or hide a real one.

e <- function(n) sprintf("EIN-10-%07d", n)

layer_db <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  x <- function(sql) DBI::dbExecute(con, sql)
  x("CREATE TABLE entity (ein VARCHAR, layer VARCHAR)")
  x(sprintf("INSERT INTO entity VALUES %s", paste(sprintf("('%s', '%s')", e(1:40),
    ifelse(1:40 %% 2 == 0, 'bmf_active', 'bmf_inactive')), collapse = ", ")))
  # names: a brand (TOASTMASTERS, concentrated) and a generic word (BAPTIST, spread)
  x("CREATE TABLE name_compact (ein VARCHAR, name_key VARCHAR, variant_class VARCHAR,
       source_mask INTEGER, first_year INTEGER, last_year INTEGER)")
  tm <- sprintf("('%s', 'TOASTMASTERS INTERNATIONAL', 'legal', 1, 2010, 2020)", e(1:12))
  tm2 <- sprintf("('%s', 'TOASTMASTERS CLUB %d', 'legal', 1, 2010, 2020)", e(13:14), 13:14)
  bp <- sprintf("('%s', '%s BAPTIST CHURCH', 'legal', 1, 2010, 2020)", e(15:28),
                c("FIRST", "SECOND", "GRACE", "HOPE", "MOUNT ZION", "NEW LIFE", "CALVARY",
                  "BETHEL", "SHILOH", "ZION HILL", "TRINITY", "EBENEZER", "FAITH", "PEACE"))
  # INTERNATIONAL, ASSOCIATION and CLUBS are common outside any one brand, as in
  # the real data
  other <- sprintf("('%s', 'ORG NUMBER %d INTERNATIONAL ASSOCIATION CLUBS', 'legal', 3, 2010, 2020)", e(29:40), 29:40)
  x(paste("INSERT INTO name_compact VALUES", paste(c(tm, tm2, bp, other), collapse = ", ")))
  # places: one shared by 2 (co-tenants), one by 5 (too many), the rest unique
  x("CREATE TABLE address_compact (ein VARCHAR, street_key VARCHAR, zip5 VARCHAR,
       state VARCHAR, n_obs INTEGER, source_mask INTEGER,
       first_vintage_year INTEGER, last_vintage_year INTEGER)")
  pl <- c(sprintf("('%s', '1 SCHOOL ST', '11111', 'ME', 1, 1, 2015, 2020)", e(29:30)),
          sprintf("('%s', '9 AGENT PLZ', '22222', 'DE', 1, 1, 2015, 2020)", e(31:35)),
          sprintf("('%s', '%d MAIN ST', '33333', 'TX', 1, 1, 2015, 2020)", e(1:28), 1:28))
  x(paste("INSERT INTO address_compact VALUES", paste(pl, collapse = ", ")))
  x("CREATE TABLE website (ein VARCHAR, site_key VARCHAR, kind VARCHAR, source VARCHAR,
       first_year INTEGER, last_year INTEGER)")
  x(sprintf("INSERT INTO website VALUES %s, ('%s', 'solo.org', 'url', 'efile990', 2020, 2020),
             ('%s', 'mail.org', 'email', 'f1023ez', 2019, 2019)",
            paste(sprintf("('%s', 'toastmasters.org', 'url', 'efile990', 2018, 2022)", e(1:3)),
                  collapse = ", "), e(36), e(37)))
  # groups: one star; relations: two Schedule R stars that share a member
  x("CREATE TABLE entity_group (ein VARCHAR, group_id VARCHAR, role VARCHAR,
       group_central_ein VARCHAR)")
  x(sprintf("INSERT INTO entity_group VALUES ('%s','GRP-10-0000001','parent','%s'),
             ('%s','GRP-10-0000001','member','%s'), ('%s','GRP-10-0000001','member','%s')",
            e(1), e(1), e(2), e(1), e(3), e(1)))
  x("CREATE TABLE ein_relation (ein_a VARCHAR, ein_b VARCHAR, relation VARCHAR, evidence VARCHAR)")
  x(sprintf("INSERT INTO ein_relation VALUES
             ('%s','%s','related_entity','schedule_r_part_ii'),
             ('%s','%s','related_entity','schedule_r_part_ii'),
             ('%s','%s','disregarded_entity','schedule_r_part_i_disregarded'),
             ('%s', NULL, 'related_entity','irs527_schedule_r'),
             ('%s','EIN-99-9999999','related_entity','schedule_r_part_ii')",
            e(36), e(37), e(38), e(37), e(38), e(39), e(40), e(40)))
  # in-care-of: name and name_derived, with legal names to point at
  x("CREATE TABLE name (name_id BIGINT, ein VARCHAR, name_raw VARCHAR, variant_class VARCHAR,
       source VARCHAR)")
  x("CREATE TABLE name_derived (name_id BIGINT, name_key VARCHAR)")
  rows <- list(
    c(1, e(36), "HOPE HOUSING INC", "legal", "HOPE HOUSING"),
    c(2, e(31), "LEHIGH CEMENT CO", "legal", "LEHIGH CEMENT"),
    c(3, e(29), "% HOPE HOUSING INC", "in_care_of", "HOPE HOUSING"),        # an org, same state? no
    c(4, e(32), "% LEHIGH CEMENT CO", "in_care_of", "LEHIGH CEMENT"),       # org, same state: link
    c(5, e(33), "% MARY SMITH", "in_care_of", "MARY SMITH"),                # person
    c(6, e(34), "% WELLS FARGO BANK NA", "in_care_of", "WELLS FARGO BANK NA"),  # agent
    c(7, e(35), "% LEHIGH CEMENT CO TREASURER", "in_care_of", "LEHIGH CEMENT TREASURER"),
    c(8, e(38), "MARY SMITH", "legal", "MARY SMITH"))
  for (r in rows) {
    x(sprintf("INSERT INTO name VALUES (%s, '%s', '%s', '%s', 'bmf')", r[1], r[2], r[3], r[4]))
    x(sprintf("INSERT INTO name_derived VALUES (%s, '%s')", r[1], r[5]))
  }
  x("CREATE TABLE address (ein VARCHAR, state VARCHAR)")
  x(sprintf("INSERT INTO address SELECT ein, state FROM address_compact"))
  x(sprintf("INSERT INTO address VALUES ('%s', 'NY'), ('%s', 'NY'), ('%s','NY')", e(36), e(37), e(38)))
  con
}

test_that("ein_key holds each identifier once per EIN, with its sharing count", {
  skip_if_not_installed("duckdb")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_ein_key(con))
  k <- DBI::dbGetQuery(con, "SELECT * FROM ein_key")
  expect_equal(nrow(k), nrow(unique(k[, c("ein", "kind", "key")])))
  expect_equal(unique(k$n_eins_sharing[k$key == "TOASTMASTERS INTERNATIONAL"]), 12)
  expect_equal(unique(k$n_eins_sharing[k$key == "9 AGENT PLZ|22222"]), 5)
  expect_equal(k$kind[k$key == "mail.org"], "email_domain")
  expect_equal(k$n_sources[k$ein == e(29) & k$kind == "name"], 2)   # source_mask 3
})

test_that("per-layer counts sum exactly to the whole-database count", {
  skip_if_not_installed("duckdb")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_ein_key(con))
  d <- DBI::dbGetQuery(con, "
    SELECT k.kind, k.key, any_value(k.n_eins_sharing) AS whole, sum(l.n_eins) AS summed
    FROM (SELECT DISTINCT kind, key, n_eins_sharing FROM ein_key) k
    JOIN ein_key_layer l USING (kind, key) GROUP BY 1, 2")
  expect_equal(d$summed, d$whole)
})

build_all <- function(con, ...) {
  suppressMessages(md_build_ein_key(con))
  suppressMessages(md_build_clusters(con, ...))
  list(c = DBI::dbGetQuery(con, "SELECT * FROM cluster"),
       m = DBI::dbGetQuery(con, "SELECT * FROM cluster_member"))
}

test_that("Schedule R gives one star per discloser, never a chained component", {
  skip_if_not_installed("duckdb")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- build_all(con, types = "related_system")
  # 36 -> 37 and 38 -> 37, 38 -> 39: two stars that share 37, not one cluster
  expect_setequal(r$c$cluster_id, c("SYS-10-0000036", "SYS-10-0000038"))
  expect_setequal(r$m$ein[r$m$cluster_id == "SYS-10-0000038"], e(c(37, 38, 39)))
  expect_equal(r$m$role[r$m$cluster_id == "SYS-10-0000036" & r$m$ein == e(36)], "central")
  # 40 lists only a NULL counterparty and an EIN outside entity: no cluster
  expect_false(any(grepl("0000040", r$c$cluster_id)))
})

test_that("in-care-of keeps organisations in the same state, not people, roles or agents", {
  skip_if_not_installed("duckdb"); skip_if_not_installed("peopleparser")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- build_all(con, types = "care_of_network")
  # only 32 -> LEHIGH CEMENT (31, both DE) survives
  expect_equal(r$c$cluster_id, "ICO-10-0000031")
  expect_setequal(r$m$ein, e(c(31, 32)))
})

test_that("a brand word concentrated in one name is a brand; a spread word is not", {
  skip_if_not_installed("duckdb")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- build_all(con, types = "brand")
  expect_true("BRD-TOASTMASTERS" %in% r$c$cluster_id)
  expect_false("BRD-BAPTIST" %in% r$c$cluster_id)
  expect_false("BRD-CHURCH" %in% r$c$cluster_id)
  # the brand reaches the two clubs whose full name differs
  expect_setequal(r$m$ein[r$m$cluster_id == "BRD-TOASTMASTERS"], e(1:14))
})

test_that("co-tenancy stops at max_cotenants; websites cluster by shared key", {
  skip_if_not_installed("duckdb")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- build_all(con, types = c("co_tenant", "shared_website"))
  expect_true("CTN-1 SCHOOL ST|11111" %in% r$c$cluster_id)
  expect_false("CTN-9 AGENT PLZ|22222" %in% r$c$cluster_id)
  expect_setequal(r$m$ein[r$m$cluster_id == "WEB-toastmasters.org"], e(1:3))
  expect_false("WEB-solo.org" %in% r$c$cluster_id)
})

test_that("one EIN sits in several clusters, and footprints sum by layer", {
  skip_if_not_installed("duckdb")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- build_all(con, types = c("group_exemption", "shared_website", "brand"))
  expect_setequal(r$m$cluster_id[r$m$ein == e(1)],
                  c("GRP-10-0000001", "WEB-toastmasters.org", "BRD-TOASTMASTERS"))
  expect_equal(r$m$role[r$m$ein == e(1) & r$m$cluster_id == "GRP-10-0000001"], "central")
  f <- DBI::dbGetQuery(con, "SELECT cluster_id, sum(n_eins) AS n FROM cluster_footprint GROUP BY 1")
  sz <- r$c[match(f$cluster_id, r$c$cluster_id), "size"]
  expect_equal(f$n, sz)
  expect_equal(r$c$brand_tokens[r$c$cluster_id == "BRD-TOASTMASTERS"], "TOASTMASTERS INTERNATIONAL")
})

test_that("an anchor with other uses needs a second brand word, trailing S ignored", {
  skip_if_not_installed("duckdb")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  x <- function(sql) DBI::dbExecute(con, sql)
  x(sprintf("INSERT INTO entity VALUES %s",
            paste(sprintf("('%s', 'bmf_active')", e(41:54)), collapse = ", ")))
  # LIONS: 10 of 14 EINs carry the full name, a share of 0.71 - a brand, but
  # one that needs a second word
  x(paste("INSERT INTO name_compact VALUES",
    paste(c(sprintf("('%s', 'INTERNATIONAL ASSOCIATION OF LIONS CLUBS', 'legal', 1, 2010, 2020)", e(41:50)),
            sprintf("('%s', 'SPRINGFIELD LIONS CLUB', 'legal', 1, 2010, 2020)", e(51)),
            sprintf("('%s', 'DETROIT LIONS ALUMNI', 'legal', 1, 2010, 2020)", e(52:54))),
          collapse = ", ")))
  r <- build_all(con, types = "brand")
  m <- r$m$ein[r$m$cluster_id == "BRD-LIONS"]
  expect_true(e(51) %in% m)            # CLUB matches CLUBS
  expect_false(any(e(52:54) %in% m))   # LIONS alone is not enough
  expect_setequal(m, e(41:51))
})

test_that("a placeholder EIN is in no group, key or cluster", {
  skip_if_not_installed("duckdb")
  con <- layer_db(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  x <- function(sql) DBI::dbExecute(con, sql)
  ph <- c("EIN-00-0000000", "EIN-12-3456789")
  # placeholders as entities, as the ingests create them from written EINs
  x(sprintf("INSERT INTO entity VALUES ('%s', 'filer_only'), ('%s', 'filer_only')", ph[1], ph[2]))
  # three disclosers write 0 or 123456789 on Schedule R; one discloser also has
  # a real related entity, so its own star survives
  x(sprintf("INSERT INTO ein_relation VALUES
             ('%s','%s','related_entity','schedule_r_part_ii'),
             ('%s','%s','related_entity','schedule_r_part_ii'),
             ('%s','%s','related_entity','schedule_r_part_ii')",
            e(2), ph[1], e(4), ph[1], e(36), ph[2]))
  # a placeholder that shares a place and a site with a real EIN
  x(sprintf("INSERT INTO address_compact VALUES ('%s', '1 SCHOOL ST', '11111', 'ME', 1, 1, 2015, 2020)", ph[1]))
  x(sprintf("INSERT INTO website VALUES ('%s', 'solo.org', 'url', 'efile990', 2020, 2020)", ph[2]))
  # a group edge to a placeholder subordinate
  x(sprintf("INSERT INTO ein_relation VALUES ('%s','%s','group_member','bmf_group_exemption')",
            e(1), ph[1]))
  suppressMessages(md_build_groups(con))
  r <- build_all(con)
  k <- DBI::dbGetQuery(con, "SELECT * FROM ein_key")
  g <- DBI::dbGetQuery(con, "SELECT * FROM entity_group")
  expect_false(any(ph %in% r$m$ein))
  expect_false(any(ph %in% k$ein))
  expect_false(any(ph %in% g$ein))
  # stars made only of a placeholder are gone; a real star is untouched
  expect_false(any(c("SYS-10-0000002", "SYS-10-0000004") %in% r$c$cluster_id))
  expect_true("SYS-10-0000036" %in% r$c$cluster_id)
  # the placeholder does not count toward a real place's sharing
  expect_equal(k$n_eins_sharing[k$kind == "place" & k$ein == e(29)], 2)
  # the raw rows stay, as provenance
  expect_equal(DBI::dbGetQuery(con, sprintf(
    "SELECT count(*) AS n FROM ein_relation WHERE ein_b = '%s'", ph[1]))$n, 3)
})
