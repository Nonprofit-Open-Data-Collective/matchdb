#!/usr/bin/env Rscript
# ============================================================================
# phase2-measure.R -- what Schedule I aliases buy on the 1k benchmark.
#
# PROCESS.md section 6's Phase 2 gate has two halves. The first - three zeros
# against the augmented BMF frozen in 0a - cannot be run as written any more:
# that frame was built from the 2026-01 BMF and an older normalizer, so it
# differs from today's database for reasons that are not Phase 2's. The
# second half can: the 1k benchmark should show the alias gain 0c measured
# (A -> B: +199 YES, -67 MAYBE), in direction and rough size.
#
# This runs the benchmark on the published active-legal and active-observed
# references and on active-observed with one corroborator, and decomposes the
# change the way 0c did: YES gained, YES lost, and YES won on an observed row.
#
#   PFMATCH_CODE=<git archive of pfmatch>  PFMATCH_INPUTS=<dir with 1k_grants_*.csv>
#   Rscript dev/verify/phase2-measure.R
# ============================================================================
suppressWarnings(suppressMessages({
  devtools::load_all(".", quiet = TRUE)
  devtools::load_all(Sys.getenv("PFMATCH_CODE"), quiet = TRUE)
}))
say <- function(...) { cat(sprintf(...), "\n"); flush.console() }
grants <- pf_read_grants(Sys.getenv("PFMATCH_INPUTS"), pattern = "^1k_grants_.*\\.csv$")
grants <- pf_recover_name_from_street(grants, verbose = FALSE)
passes <- c(pf_staged_passes("lean", concat = TRUE), pf_recovery_passes(state = TRUE))

run <- function(bundle) {
  m <- pf_match_grants(grants, bundle, passes = passes, recover = TRUE, verbose = FALSE)
  r <- as.data.frame(m$result)
  r[order(r$.id), ]
}
arms <- list()
for (lab in c("active-legal", "active-observed")) {
  b <- md_reference(lab)
  say("%-16s %s  %s rows", lab, b$stamp$spec_hash, format(nrow(b$reference), big.mark = ","))
  arms[[lab]] <- run(b)
}
# one corroborator: every Schedule I spelling, not only those two filers agree on
con <- md_db(read_only = TRUE)
sp1 <- md_spec(layers = "bmf_active", names = c("legal", "dba", "observed"),
               addresses = c("mailing", "observed"), min_corroborators = 1,
               label = "active-observed-1")
c1 <- md_compile(sp1, con); md_db_close(con)
say("%-16s %s  %s rows", "active-observed-1", sp1$spec_hash,
    format(nrow(c1$reference), big.mark = ","))
arms[["active-observed-1"]] <- run(list(reference = c1$reference, name_freq = c1$name_freq,
                                        token_idf = c1$token_idf,
                                        ref_index = npmatch::np_ref_index(c1$reference)))

say("\n%-18s %6s %6s %6s %7s", "arm", "YES", "MAYBE", "NO", "ids")
for (a in names(arms)) {
  t <- table(factor(arms[[a]]$tier, c("YES", "MAYBE", "NO")))
  say("%-18s %6d %6d %6d %7d", a, t[["YES"]], t[["MAYBE"]], t[["NO"]], nrow(arms[[a]]))
}
base <- arms[["active-legal"]]
for (a in setdiff(names(arms), "active-legal")) {
  x <- arms[[a]]
  ids <- union(base$.id, x$.id)
  tb <- stats::setNames(as.character(base$tier), base$.id)[ids]; tb[is.na(tb)] <- "NONE"
  tx <- stats::setNames(as.character(x$tier), x$.id)[ids]; tx[is.na(tx)] <- "NONE"
  eb <- stats::setNames(base$overall_ein, base$.id)[ids]; ex <- stats::setNames(x$overall_ein, x$.id)[ids]
  say("\nactive-legal -> %s", a)
  say("  YES gained %d, YES lost %d, net %+d", sum(tx == "YES" & tb != "YES"),
      sum(tb == "YES" & tx != "YES"), sum(tx == "YES") - sum(tb == "YES"))
  say("  MAYBE net %+d", sum(tx == "MAYBE") - sum(tb == "MAYBE"))
  say("  YES in both with a different EIN: %d", sum(tb == "YES" & tx == "YES" & eb != ex, na.rm = TRUE))
}
