#!/usr/bin/env Rscript
# ============================================================================
# eval-cluster-rollup.R -- does matching one level up help, on queries whose
# answer is known?
#
# Ground truth comes from Schedule I: filers report the recipient's EIN next to
# the name and address they wrote. A sample of those (name, own address, EIN)
# rows, for EINs in the active BMF, is matched as if it were 990-PF grants
# against the active-legal reference - legal and DBA names only, so the
# observed spelling being matched is not itself in the reference. Then:
#
#   EIN level      YES / MAYBE / NO, and how often the EIN is right
#   roll-up        of the queries short of YES, how many np_cluster_rollup()
#                  places in a family, and how often the true EIN is in it
#   pair links     how often the top two candidates are one family, and among
#                  family contests how often the runner-up is the truth
#
#   PFMATCH_CODE=<git archive of pfmatch>  NPMATCH_CODE=<npmatch checkout>
#   MD_EVAL_N=2000  Rscript dev/verify/eval-cluster-rollup.R
# ============================================================================
suppressWarnings(suppressMessages({
  if (nzchar(Sys.getenv("NPMATCH_CODE"))) devtools::load_all(Sys.getenv("NPMATCH_CODE"), quiet = TRUE)
  devtools::load_all(".", quiet = TRUE)
  devtools::load_all(Sys.getenv("PFMATCH_CODE"), quiet = TRUE)
}))
say <- function(...) { cat(sprintf(...), "\n"); flush.console() }
N <- as.integer(Sys.getenv("MD_EVAL_N", "2000"))
set.seed(20261022)

## ---- truth sample from Schedule I ------------------------------------------------
con <- md_db(read_only = TRUE)
s <- DBI::dbGetQuery(con, "
  SELECT n.ein, n.name_raw, a.street_raw, a.city_raw, a.state, a.zip5
  FROM name n
  JOIN entity e ON e.ein = n.ein AND e.layer = 'bmf_active'
  JOIN address a ON a.name_id = n.name_id AND a.variant_class = 'observed'
  WHERE n.source = 'schedi' AND n.variant_class = 'observed'
    AND coalesce(a.street_raw, '') <> '' AND coalesce(a.zip5, '') <> ''")
md_db_close(con)
say("Schedule I (name, own address, EIN) rows for active EINs: %s",
    format(nrow(s), big.mark = ","))
s <- s[sample.int(nrow(s), min(N, nrow(s))), ]
g <- data.frame(SIGOCPYRPNAM = "", SIGOCPYRBNBN1 = s$name_raw, SIGOCPYRBNBN2 = "",
                SIGOCPYRFAAL1 = s$street_raw, SIGOCPYRFAAL2 = "", SIGOCPYRFACI = s$city_raw,
                SIGOCPYRFAPO = s$state, SIGOCPYRFAPC = s$zip5, SIGOCPYRFSTA = "PC",
                SIGOCPYRRELA = "NONE", TRUTH_EIN = s$ein, stringsAsFactors = FALSE)
grants <- pf_prepare_grants(g)
grants <- pf_recover_name_from_street(grants, verbose = FALSE)
truth <- stats::setNames(grants$TRUTH_EIN, grants$grant_id)

## ---- EIN level ---------------------------------------------------------------------
b <- md_reference("active-legal")
say("reference active-legal %s: %s rows, %s cluster memberships", b$stamp$spec_hash,
    format(nrow(b$reference), big.mark = ","), format(nrow(b$clusters), big.mark = ","))
passes <- c(pf_staged_passes("lean", concat = TRUE), pf_recovery_passes(state = TRUE))
m <- pf_match_grants(grants, b, passes = passes, recover = TRUE, verbose = FALSE)
res <- as.data.frame(m$result); pairs <- attr(m$result, "pairs")
res$truth <- truth[res$.id]
res$right <- !is.na(res$overall_ein) & res$overall_ein == res$truth
tab <- table(factor(res$tier, c("YES", "MAYBE", "NO")))
say("\nEIN level, %d in-scope queries", nrow(res))
for (t in names(tab)) say("  %-5s %5d  right EIN %5.1f%%", t, tab[[t]],
                          100 * mean(res$right[res$tier == t]))

## ---- roll-up -------------------------------------------------------------------------
query <- npmatch::np_normalize(npmatch::np_query(grants[grants$in_scope, ], pf_map_grants()))
cl <- b$clusters
fam <- split(cl$cluster_id, cl$ein)
in_family <- function(ids, eins, cids) mapply(function(e, c) c %in% fam[[e]], eins, cids)
for (types in list(NULL, "group_exemption", "related_system", "brand", "co_tenant",
                   "care_of_network", "shared_website")) {
  ru <- np_cluster_rollup(res, cl, pairs, query = query, types = types)
  if (!nrow(ru)) { say("  %-16s no roll-ups", if (is.null(types)) "all types" else types); next }
  ok <- in_family(ru$.id, truth[ru$.id], ru$cluster_id)
  was <- res$tier[match(ru$.id, res$.id)]
  say("\nroll-up, %s: %d of %d non-YES queries placed in a family; truth in it %.1f%%",
      if (is.null(types)) "all types" else types, nrow(ru), sum(res$tier != "YES"),
      100 * mean(ok))
  print(table(basis = ru$basis, truth_in_family = ok))
  print(table(type = ru$cluster_type, was = was))
}

## ---- pair links ----------------------------------------------------------------------
pl <- np_pair_links(res, cl, pairs)
pl$tier <- res$tier[match(pl$.id, res$.id)]
pl$truth <- truth[pl$.id]
say("\npair links over %d queries with two or more candidates", nrow(pl))
say("  top two are one family: %d (%.1f%%)", sum(pl$linked), 100 * mean(pl$linked))
fc <- pl[pl$family_contest, ]
say("  family contests (YES by < 0.05 over a linked sibling): %d", nrow(fc))
if (nrow(fc)) {
  say("    winner is the truth %d, runner-up is the truth %d, neither %d",
      sum(fc$top_ein == fc$truth), sum(fc$runner_up_ein == fc$truth),
      sum(fc$top_ein != fc$truth & fc$runner_up_ein != fc$truth))
  print(table(fc$link_types))
}
yes <- pl[pl$tier == "YES", ]
say("  YES queries: wrong EIN %d of %d; of the wrong ones, runner-up linked %d, runner-up is the truth %d",
    sum(yes$top_ein != yes$truth), nrow(yes), sum(yes$linked & yes$top_ein != yes$truth),
    sum(yes$runner_up_ein == yes$truth & yes$top_ein != yes$truth))
