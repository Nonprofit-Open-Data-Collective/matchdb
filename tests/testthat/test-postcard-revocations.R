# The e-Postcard and revocation ingests, and the incremental derived build
# they rely on. The rules: new EINs get their own layer and nothing else is
# re-layered, dates parse into dated events, a person's details are never read,
# and an incremental derive equals a full one.

e <- function(n) sprintf("EIN-00-%07d", n)

pr_db <- function() {
  skip_if_not_installed("duckdb")
  root <- tempfile("mdroot"); dir.create(root)
  old <- Sys.getenv("MATCHDB_DATA", unset = NA)
  Sys.setenv(MATCHDB_DATA = root)
  withr_defer <- function() {
    if (is.na(old)) Sys.unsetenv("MATCHDB_DATA") else Sys.setenv(MATCHDB_DATA = old)
    unlink(root, recursive = TRUE)
  }
  con <- DBI::dbConnect(duckdb::duckdb())
  x <- function(sql) DBI::dbExecute(con, sql)
  x("CREATE TABLE entity (ein VARCHAR, layer VARCHAR, active BOOLEAN, source_vintage VARCHAR)")
  x(sprintf("INSERT INTO entity VALUES ('%s','bmf_active',TRUE,'b'), ('%s','filer_only',FALSE,'h')",
            e(1), e(2)))
  x("CREATE TABLE name (name_id INTEGER, ein VARCHAR, name_raw VARCHAR, variant_class VARCHAR,
       source VARCHAR, source_vintage VARCHAR, n_obs INTEGER, n_corroborators INTEGER,
       first_year INTEGER, last_year INTEGER)")
  x(sprintf("INSERT INTO name VALUES (1,'%s','ALPHA CLUB','legal','bmf','b',NULL,NULL,NULL,NULL)", e(1)))
  x("CREATE TABLE address (address_id INTEGER, ein VARCHAR, name_id INTEGER, street_raw VARCHAR,
       city_raw VARCHAR, state VARCHAR, zip5 VARCHAR, zip_plus4 VARCHAR, variant_class VARCHAR,
       spell_rank INTEGER, source VARCHAR, source_vintage VARCHAR, n_obs INTEGER,
       first_vintage VARCHAR, last_vintage VARCHAR)")
  x(sprintf("INSERT INTO address VALUES (1,'%s',NULL,'1 MAIN ST','OGDEN','UT','84401',NULL,
             'mailing',0,'bmf','b',1,NULL,NULL)", e(1)))
  # an e-Postcard: e1 (already in the BMF), e3 new and terminated, e4 new
  d <- md_path("sources", "e_postcard", "v2026-07", create = TRUE)
  writeLines(c(paste0('"ein","tax_year","legal_name","terminated","tax_period_end_date","website",',
                      '"officer_name","officer_address_line_1","organization_address_line_1",',
                      '"organization_city","organization_state","organization_zip",',
                      '"dba_name_1","dba_name_2","dba_name_3"'),
               '"000000001","2024","ALPHA CLUB","F","12-31-2024","","Jane Doe","9 HOME LN","1 MAIN ST","OGDEN","UT","84401-1234","ALPHA BOOSTERS","",""',
               '"000000003","2019","GAMMA LEAGUE","T","06-30-2019","","John Roe","8 HOME LN","3 OAK ST","PROVO","UT","84601","","",""',
               '"000000004","2025","DELTA GUILD","F","12-31-2025","","Ann Poe","7 HOME LN","4 ELM ST","LOGAN","UT","84321","","",""'),
             file.path(d, "2026-07-E-POSTCARD.csv"))
  writeLines(c("source: e_postcard", "url: local", "fetched: 2026-10-22"), file.path(d, "PIN.dcf"))
  # revocations: e2 (filer) revoked then reinstated, e4 (postcard) revoked, e5 new, twice
  d <- md_path("sources", "revocations", "v2026-07", create = TRUE)
  writeLines(c(paste0('"ein","legal_name","doing_business_as_name","organization_address","city",',
                      '"state","zip_code","country","exemption_type","revocation_date",',
                      '"revocation_posting_date","exemption_reinstatement_date"'),
               '"000000002","BETA FUND","","2 PINE ST","OGDEN","UT","84401","US","03","15-MAY-2018","10-AUG-2018","01-JAN-2020"',
               '"000000004","DELTA GUILD","","4 ELM ST","LOGAN","UT","84321","US","03","15-MAY-2026","09-JUN-2026",""',
               '"000000005","EPSILON CLUB","EPS CLUB","5 FIR ST","OREM","UT","84057","US","04","15-MAY-2011","13-JUN-2011",""',
               '"000000005","EPSILON CLUB","","5 FIR ST","OREM","UT","84057","US","04","15-MAY-2017","10-JUL-2017",""'),
             file.path(d, "2026-07-REVOCATIONS-ORGS.csv"))
  writeLines(c("source: revocations", "url: local", "fetched: 2026-10-22"), file.path(d, "PIN.dcf"))
  list(con = con, done = function() { DBI::dbDisconnect(con, shutdown = TRUE); withr_defer() })
}

test_that("the e-Postcard adds new EINs as postcard_only and re-layers nothing", {
  db <- pr_db(); on.exit(db$done()); con <- db$con
  suppressMessages(md_ingest_e_postcard("v2026-07", con))
  ent <- DBI::dbGetQuery(con, "SELECT ein, layer FROM entity ORDER BY ein")
  expect_equal(ent$layer, c("bmf_active", "filer_only", "postcard_only", "postcard_only"))
  nm <- DBI::dbGetQuery(con, "SELECT ein, name_raw, variant_class, first_year FROM name
                              WHERE source = 'e_postcard' ORDER BY ein, variant_class")
  expect_equal(nm$name_raw, c("ALPHA BOOSTERS", "ALPHA CLUB", "GAMMA LEAGUE", "DELTA GUILD"))
  expect_equal(nm$first_year[nm$ein == e(3)], 2019)
  ad <- DBI::dbGetQuery(con, "SELECT * FROM address WHERE source = 'e_postcard' ORDER BY ein")
  expect_equal(ad$variant_class, rep("mailing", 3))
  expect_equal(ad$zip_plus4[ad$ein == e(1)], "1234")
  expect_false(any(grepl("HOME LN", ad$street_raw)))          # never the officer's address
  ev <- DBI::dbGetQuery(con, "SELECT * FROM entity_event")
  expect_equal(ev$ein, e(3)); expect_equal(ev$event, "terminated_990n")
  expect_equal(as.character(ev$event_date), "2019-06-30")
})

test_that("revocations add dated events, and only EINs on no other list are revoked_only", {
  db <- pr_db(); on.exit(db$done()); con <- db$con
  suppressMessages(md_ingest_e_postcard("v2026-07", con))
  suppressMessages(md_ingest_revocations("v2026-07", con))
  ent <- DBI::dbGetQuery(con, "SELECT ein, layer FROM entity ORDER BY ein")
  expect_equal(ent$layer[ent$ein == e(4)], "postcard_only")   # already known
  expect_equal(ent$layer[ent$ein == e(5)], "revoked_only")
  ev <- DBI::dbGetQuery(con, "SELECT ein, event, event_date FROM entity_event
                              WHERE source = 'revocations' ORDER BY ein, event_date, event")
  expect_equal(ev$event[ev$ein == e(2)], c("revoked", "revocation_posted", "reinstated"))
  expect_equal(as.character(ev$event_date[ev$ein == e(2) & ev$event == "reinstated"]), "2020-01-01")
  expect_equal(sum(ev$ein == e(5) & ev$event == "revoked"), 2)   # revoked twice
  nm <- DBI::dbGetQuery(con, "SELECT name_raw, variant_class, first_year, last_year FROM name
                              WHERE source = 'revocations' AND ein = 'EIN-00-0000005'
                              ORDER BY variant_class")
  expect_equal(nm$name_raw, c("EPS CLUB", "EPSILON CLUB"))
  expect_equal(c(nm$first_year[2], nm$last_year[2]), c(2011, 2017))
  ad <- DBI::dbGetQuery(con, "SELECT variant_class FROM address WHERE source = 'revocations'")
  expect_true(all(ad$variant_class == "historical"))
})

test_that("re-running an ingest replaces its own rows rather than adding to them", {
  db <- pr_db(); on.exit(db$done()); con <- db$con
  for (i in 1:2) {
    suppressMessages(md_ingest_e_postcard("v2026-07", con))
    suppressMessages(md_ingest_revocations("v2026-07", con))
  }
  n <- DBI::dbGetQuery(con, "SELECT source, count(*) AS n FROM name GROUP BY 1 ORDER BY 1")
  expect_equal(n$n, c(1, 4, 4))   # bmf, e_postcard, revocations: as after one run
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM entity")), 5)
  # 1 termination + revocations: e2 3 dates, e4 2, e5 twice revoked and posted
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM entity_event")$n, 10)
})

test_that("an incremental derive equals a full one, and drops rows whose source is gone", {
  db <- pr_db(); on.exit(db$done()); con <- db$con
  suppressMessages(md_build_derived(con, chunk = 2L))
  suppressMessages(md_ingest_e_postcard("v2026-07", con))
  suppressMessages(md_ingest_revocations("v2026-07", con))
  DBI::dbExecute(con, "DELETE FROM name WHERE name_id = 1")    # a row that goes away
  suppressMessages(md_build_derived(con, chunk = 2L, incremental = TRUE))
  inc <- list(n = DBI::dbGetQuery(con, "SELECT * FROM name_derived ORDER BY name_id"),
              a = DBI::dbGetQuery(con, "SELECT * FROM address_derived ORDER BY address_id"))
  suppressMessages(md_build_derived(con, chunk = 2L))
  full <- list(n = DBI::dbGetQuery(con, "SELECT * FROM name_derived ORDER BY name_id"),
               a = DBI::dbGetQuery(con, "SELECT * FROM address_derived ORDER BY address_id"))
  expect_identical(inc, full)
  expect_false(1 %in% inc$n$name_id)
  DBI::dbExecute(con, "UPDATE name_derived SET normalize_signature = 'v1-other'")
  expect_error(suppressMessages(md_build_derived(con, incremental = TRUE)), "mix two")
})

test_that("a person key ignores order, punctuation, initials and titles", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  x <- c("SMITH, JOHN A", "John Smith", "DR. JOHN A. SMITH JR", "Rev John Smith, PhD",
         "MARY", "J K", "", "O'BRIEN, MARY-KATE")
  duckdb::duckdb_register(con, "t", data.frame(i = seq_along(x), nm = x))
  k <- DBI::dbGetQuery(con, sprintf("SELECT %s AS k FROM t ORDER BY i",
                                    .md_person_key_sql("nm")))$k
  expect_equal(k[1:4], rep("JOHN SMITH", 4))
  expect_true(all(is.na(k[5:7])))          # one word, or no words of 2+ letters
  expect_equal(k[8], "BRIEN KATE MARY")
})

test_that("officer keys are written per EIN with years, and feed ein_key", {
  db <- pr_db(); on.exit(db$done()); con <- db$con
  d <- md_path("sources", "efile_officers", "v3_1", create = TRUE)
  hdr <- "EIN2,TAX_YEAR,F9_07_COMP_DTK_NAME_PERS,F9_07_COMP_DTK_TITLE,F9_07_COMP_DTK_COMP_ORG"
  writeLines(c(hdr, "EIN-00-0000001,2019,\"SMITH, JOHN\",PRESIDENT,90000",
               "EIN-00-0000001,2021,John Smith,TREASURER,0",
               "EIN-00-0000002,2021,Mary Jones,DIRECTOR,0", "EIN-00-0000099,2021,Al Unknown,CEO,1"),
             file.path(d, "F9-P07-T01-COMPENSATION-2021.CSV"))
  writeLines(c("source: efile_officers", "url: local", "fetched: 2026-10-22"), file.path(d, "PIN.dcf"))
  suppressMessages(md_ingest_officers("v3_1", con))
  p <- DBI::dbGetQuery(con, "SELECT * FROM person_key ORDER BY ein")
  expect_equal(p$person_key[p$ein == e(1)], "JOHN SMITH")
  expect_equal(c(p$first_year[p$ein == e(1)], p$last_year[p$ein == e(1)], p$n_obs[p$ein == e(1)]),
               c(2019, 2021, 2))
  expect_false(any(c("F9_07_COMP_DTK_TITLE", "title", "comp") %in% names(p)))   # keys only
})
