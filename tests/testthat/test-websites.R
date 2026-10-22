# Website fields are free text. These are the values seen in the e-file header,
# 1023-EZ and e-Postcard: a cleaning rule that keeps a placeholder, or splits one
# organisation's site into two keys, damages every match that uses it.

clean <- function(x) {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  duckdb::duckdb_register(con, "t", data.frame(i = seq_along(x), v = x,
                                                stringsAsFactors = FALSE))
  DBI::dbGetQuery(con, sprintf("SELECT * FROM (%s) ORDER BY i",
                               .md_website_clean_sql("t", "v")))
}

test_that("placeholders and non-websites are rejected, not listed one by one", {
  x <- c("N/A", "NONE", "TBD", "SEE SCHEDULE O", "UNDER CONSTRUCTION",
         "xxx-xx-xxxx", "California Schools Employee Association", "0", "",
         "Monument Lodge 96", "www", "http://")
  expect_true(all(is.na(clean(x)$site_key)))
})

test_that("one site written many ways gets one key", {
  x <- c("WWW.ELKS.ORG", "http://www.elks.org/", "https://elks.org", "elks.org/",
         "www,elks.org", "  Elks.Org  ", "www.elks.org:443", "HTTP://WWW2.ELKS.ORG")
  got <- clean(x)
  expect_equal(unique(got$site_key), "elks.org")
  expect_true(all(got$kind == "url"))
  expect_false(any(got$is_platform))
})

test_that("a path is kept in the url but not in the key of an ordinary site", {
  got <- clean("HTTP://WWW.AUB.EDU.LB/ALUMNI/PAGES/HOME.ASPX")
  expect_equal(got$site_key, "aub.edu.lb")
  expect_equal(got$host, "aub.edu.lb")
  expect_equal(got$url, "aub.edu.lb/alumni/pages/home.aspx")
})

test_that("an email address is kept by its domain unless the provider is personal", {
  got <- clean(c("info@hullscove.org", "treasurer@gmail.com", "Bob@Yahoo.com"))
  expect_equal(got$site_key, c("hullscove.org", NA, NA))
  expect_equal(got$kind[1], "email")
})

test_that("a platform page is keyed by its first path segment", {
  got <- clean(c("https://www.facebook.com/HullsCove/", "facebook.com",
                 "mylodge.wixsite.com/home", "linktr.ee/friends_of_x",
                 "https://sites.google.com/view/troop12"))
  expect_equal(got$site_key, c("facebook.com/hullscove", NA, "mylodge.wixsite.com",
                               "linktr.ee/friends_of_x", "sites.google.com/view/troop12"))
  expect_true(all(got$is_platform[!is.na(got$site_key)]))
})

test_that("other columns pass through untouched", {
  got <- clean(c("kdp.org", "nope"))
  expect_equal(got$i, 1:2)
  expect_equal(got$v, c("kdp.org", "nope"))
})

test_that("a generic first segment on a platform takes the next one as the identity", {
  got <- clean(c("https://sites.google.com/view/troop12/home", "sites.google.com/view",
                 "facebook.com/groups/123456/", "www.facebook.com/pages/Hulls-Cove/99",
                 "leaguelineup.com/eastsideyouth", "e-clubhouse.org/sites/mainelions"))
  expect_equal(got$site_key, c("sites.google.com/view/troop12", NA,
                               "facebook.com/groups/123456", "facebook.com/pages/hulls-cove",
                               "leaguelineup.com/eastsideyouth",
                               "e-clubhouse.org/sites/mainelions"))
})

test_that("a platform page file or search page is not an identity", {
  got <- clean(c("leaguelineup.com/welcome.asp?url=eastside", "tshq.bluesombrero.com/default.aspx",
                 "facebook.com/search/top?q=lions", "elks.org/default.aspx"))
  # bluesombrero subdomains (tshq, clubs, leagues) are shared by hundreds of
  # leagues; the league is in the query string, so these pages name no one
  expect_equal(got$site_key, c(NA, NA, NA, "elks.org"))
})

test_that("a page on its own platform subdomain is keyed by the subdomain", {
  got <- clean(c("eastsidelions.weebly.com/about", "eastsidelions.weebly.com",
                 "m.facebook.com/hullscove",
                 "weebly.com"))
  expect_equal(got$site_key, c("eastsidelions.weebly.com", "eastsidelions.weebly.com",
                               "facebook.com/hullscove", NA))
})
