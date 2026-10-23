# Check a built MATCHDB.duckdb before it is shared.
#
#   Rscript dev/check-build.R              # md_data_root()/db/MATCHDB.duckdb
#   Rscript dev/check-build.R <path>
#
# A build can finish with every step "done" and still be wrong: a source that
# loaded one year instead of ten, or a derived table built against stale ids.
# These checks look for that kind of quiet failure. Exit status 1 if any fails.

suppressMessages(pkgload::load_all(".", quiet = TRUE))
options(width = 200)
args <- commandArgs(TRUE)
db <- if (length(args)) args[1] else md_path("db", "MATCHDB.duckdb")
con <- md_db(read_only = TRUE, path = db)
on.exit(md_db_close(con))
q <- function(s) DBI::dbGetQuery(con, s)

results <- list()
check <- function(label, ok, detail = "") {
  results[[length(results) + 1L]] <<- data.frame(check = label, ok = isTRUE(ok),
                                                 detail = detail)
}

## every core and derived table exists and is non-empty
tabs <- c("entity", "name", "address", "orgtext", "ein_relation", "source_vintage",
          "name_derived", "address_derived", "name_compact", "address_compact",
          "entity_group", "website", "ein_key", "ein_key_layer", "cluster",
          "cluster_member", "cluster_footprint", "entity_event")
for (t in tabs) {
  n <- if (DBI::dbExistsTable(con, t)) .md_n(con, t) else NA
  check(sprintf("%s is non-empty", t), !is.na(n) && n > 0,
        if (is.na(n)) "missing" else format(n, big.mark = ","))
}

## derived tables were built against the current ids
fresh <- md_check_derived_fresh(con, stop_on_stale = FALSE)
check("derived tables are fresh", all(fresh$orphaned_rows == 0),
      paste(fresh$table, fresh$orphaned_rows, collapse = ", "))

## every row's EIN is a known entity
for (t in c("name", "address", "website", "ein_key", "cluster_member")) {
  n <- q(sprintf("SELECT count(*) AS n FROM %s x ANTI JOIN entity e USING (ein)", t))$n
  check(sprintf("every %s EIN is in entity", t), n == 0, format(n, big.mark = ","))
}

## each source covers the years it should
yr <- function(src, lo, hi, tbl = "name") {
  r <- q(sprintf("SELECT min(first_year) lo, max(last_year) hi FROM %s WHERE source = '%s'",
                 tbl, src))
  check(sprintf("%s %s spans %d-%d", tbl, src, lo, hi),
        isTRUE(r$lo <= lo && r$hi >= hi), sprintf("%s-%s", r$lo, r$hi))
}
yr("f1023ez", 2014, 2023)
yr("schedi", 2009, 2025)
yr("efile990", 2009, 2025)
r <- q("SELECT min(first_year) lo, max(last_year) hi FROM ein_relation
        WHERE source = 'efile_afl'")
check("affiliate listing spans 2009-2025", isTRUE(r$lo <= 2009 && r$hi >= 2025),
      sprintf("%s-%s", r$lo, r$hi))
r <- q("SELECT count(DISTINCT approval_year) AS n FROM (
          SELECT DISTINCT first_year AS approval_year FROM name WHERE source = 'f1023ez'
          UNION SELECT DISTINCT last_year FROM name WHERE source = 'f1023ez')")
check("1023-EZ has all ten approval years", isTRUE(r$n >= 10), r$n)

## every ingest recorded itself
need <- c("bmf_unified", "f1023ez", "efile_header", "schedi", "efile_related",
          "efile_disregarded", "efile_related_ptr", "efile_related_corp",
          "efile_orgtext", "efile_affiliate_listing", "efile_sched_c_affil",
          "address_crosswalk", "address_geocoded", "meta_group_number",
          "irs527_related", "e_postcard", "revocations")
have <- q("SELECT DISTINCT source FROM source_vintage")$source
check("every source is in source_vintage", all(need %in% have),
      paste(setdiff(need, have), collapse = ", "))

## websites come from all three sources, and no placeholder survived as a key
r <- q("SELECT count(DISTINCT source) AS n FROM website")
check("website has all three sources", isTRUE(r$n == 3), r$n)
r <- q("SELECT count(*) AS n FROM website WHERE site_key IN ('n/a', 'none', 'na', 'tbd')
          OR site_key NOT LIKE '%.%'")
check("no website key is a placeholder", isTRUE(r$n == 0), r$n)

## the identifier and cluster layers are internally consistent
r <- q("SELECT count(*) AS n FROM (SELECT kind, key, any_value(n_eins_sharing) AS w FROM ein_key GROUP BY 1, 2) k
        JOIN (SELECT kind, key, sum(n_eins) AS s FROM ein_key_layer GROUP BY 1, 2) l USING (kind, key)
        WHERE k.w <> l.s")
check("ein_key_layer sums to n_eins_sharing", isTRUE(r$n == 0), r$n)
r <- q("SELECT count(*) AS n FROM cluster c JOIN (SELECT cluster_id, count(*) AS m FROM cluster_member GROUP BY 1) m
        USING (cluster_id) WHERE c.size <> m.m OR c.size < 2")
check("every cluster has size >= 2 and matches its members", isTRUE(r$n == 0), r$n)
r <- q("SELECT count(DISTINCT cluster_type) AS n, max(size) FILTER (WHERE cluster_type = 'brand') AS b FROM cluster")
check("all six cluster types, and no runaway brand", isTRUE(r$n == 6 && r$b < 50000),
      sprintf("%s types, largest brand %s", r$n, format(r$b, big.mark = ",")))

## groups use only group_member edges
r <- q("SELECT max(group_size) AS m, count(DISTINCT group_id) AS g FROM entity_group")
check("largest group is a group, not the related-entity giant", isTRUE(r$m < 50000),
      sprintf("%s groups, largest %s", format(r$g, big.mark = ","),
              format(r$m, big.mark = ",")))

out <- do.call(rbind, results)
print(out, row.names = FALSE, right = FALSE)
cat("\n")
print(q("SELECT layer, count(*) AS n FROM entity GROUP BY 1 ORDER BY 2 DESC"))
print(q("SELECT variant_class, source, count(*) AS n FROM name GROUP BY 1, 2 ORDER BY 3 DESC"))
print(q("SELECT relation, evidence, count(*) AS n FROM ein_relation GROUP BY 1, 2 ORDER BY 3 DESC"))
cat(sprintf("\n%d of %d checks passed\n", sum(out$ok), nrow(out)))
if (!all(out$ok)) quit(status = 1)
