#!/usr/bin/env Rscript
# ============================================================================
# probe-compaction.R -- build name_compact / address_compact against the live
# database and report the numbers dev/COMPACTION.md cites.
# ============================================================================
suppressWarnings(suppressMessages(devtools::load_all(".")))
con <- md_db()
on.exit(md_db_close(con))
Q <- function(s) DBI::dbGetQuery(con, s)
say <- function(...) cat(sprintf(...), "\n")
hr <- function() cat(strrep("-", 78), "\n")

t0 <- Sys.time()
md_build_compact(con)
say("\nbuild time: %.1f min", as.numeric(difftime(Sys.time(), t0, units = "mins")))

hr(); say("NAME COMPACT")
print(Q("SELECT count(*) AS n_rows, count(DISTINCT ein) AS eins FROM name_compact"))
say("")
say("variant_class after collapsing across sources:")
print(Q("SELECT variant_class, count(*) n FROM name_compact GROUP BY 1 ORDER BY n DESC"))
say("")
say("source_mask popcount (how many sources corroborate one name):")
print(Q("SELECT bit_count(source_mask) AS n_sources, count(*) n
         FROM name_compact GROUP BY 1 ORDER BY 1"))
say("")
say("n_eins_sharing distribution (recomputed on the real name_key):")
print(Q("SELECT CASE WHEN n_eins_sharing = 1 THEN '1 (unique)'
                     WHEN n_eins_sharing <= 3 THEN '2-3'
                     WHEN n_eins_sharing <= 10 THEN '4-10'
                     WHEN n_eins_sharing <= 100 THEN '11-100'
                     ELSE '100+' END AS bucket,
                count(DISTINCT name_key) n_keys, sum(1) n_rows
         FROM name_compact GROUP BY 1 ORDER BY min(n_eins_sharing)"))
say("")
say("year envelope fill (post section-0 fixes):")
print(Q("SELECT round(100.0*avg(CASE WHEN first_year IS NOT NULL THEN 1 ELSE 0 END),1) pct
         FROM name_compact"))

hr(); say("ADDRESS COMPACT")
print(Q("SELECT count(*) AS n_rows, count(DISTINCT ein) AS eins FROM address_compact"))
say("")
say("source_mask popcount:")
print(Q("SELECT bit_count(source_mask) AS n_sources, count(*) n
         FROM address_compact GROUP BY 1 ORDER BY 1"))
say("")
say("street_key fill after domination pruning (should be much higher than raw):")
print(Q("SELECT round(100.0*avg(CASE WHEN street_key IS NOT NULL THEN 1 ELSE 0 END),1) pct_street
         FROM address_compact"))
print(Q("SELECT round(100.0*avg(CASE WHEN street_raw IS NOT NULL THEN 1 ELSE 0 END),1) pct_street_raw_before
         FROM address"))
say("")
say("vintage_year fill and range (the derived canonical key, section 0's fix):")
print(Q("SELECT round(100.0*avg(CASE WHEN last_vintage_year IS NOT NULL THEN 1 ELSE 0 END),1) pct,
                min(last_vintage_year) lo, max(last_vintage_year) hi
         FROM address_compact"))

hr(); say("DOMINATION PRUNING: sample of what it caught")
print(Q("
  WITH raw_place AS (
    SELECT ein, nullif(upper(trim(street_raw)),'') street_key,
           nullif(upper(trim(city_raw)),'') city_key, state, zip5
    FROM address GROUP BY 1,2,3,4,5
  ), coarse AS (
    SELECT * FROM raw_place WHERE street_key IS NULL
  )
  SELECT c.ein, c.city_key, c.state, c.zip5,
         (SELECT count(*) FROM address_compact ac
          WHERE ac.ein = c.ein AND ac.street_key IS NOT NULL) AS survives_as_fuller_row
  FROM coarse c LIMIT 6"))

hr(); say("db size: %.2f GB", file.size(md_path("db", "MATCHDB.duckdb")) / 1024^3)
