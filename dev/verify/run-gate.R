#!/usr/bin/env Rscript
# ============================================================================
# run-gate.R -- evaluate a phase gate against the frozen baseline.
#
# Usage:
#   MD_GATE=selftest  Rscript dev/verify/run-gate.R
#   MD_GATE=phase1    Rscript dev/verify/run-gate.R   (once md_compile exists)
#
# `selftest` is gate 0d, and it is not ceremony. It runs the harness on the
# real baseline against ITSELF and requires three zeros. A harness that cannot
# report "no difference" when there is none makes every later gate
# unfalsifiable, so this has to pass before Phase 1 can mean anything.
#
# Exit status is the gate: 0 = pass, 1 = fail. Wire it into CI as-is.
#
#   MD_BASELINE=<dir>  default ../pfmatch/dev/BASELINE-2026-08
# ============================================================================
suppressWarnings(suppressMessages(devtools::load_all(
  Sys.getenv("MATCHDB_DIR", "."), quiet = TRUE)))

GATE <- Sys.getenv("MD_GATE", "selftest")
BASE <- Sys.getenv("MD_BASELINE",
                   file.path("..", "pfmatch", "dev", "BASELINE-2026-08"))
say  <- function(...) { cat(sprintf(...), "\n"); flush.console() }
hr   <- function() cat(strrep("=", 78), "\n")

if (!dir.exists(BASE))
  stop("no baseline at ", BASE, " -- run pfmatch/dev/build-baseline.R first")

man <- utils::read.csv(file.path(BASE, "manifest.csv"), stringsAsFactors = FALSE)
env <- readLines(file.path(BASE, "environment.txt"))
hr(); say("GATE: %s", GATE); say("baseline: %s", normalizePath(BASE)); hr()
cat(grep("^(pfmatch|npmatch|R |normalizer)", env, value = TRUE), sep = "\n")
say("")

# The signature the baseline was built against must still be the one installed.
# Comparing artifacts normalized by two different normalizers produces diffs
# that look behavioural and are not -- and, worse, hides real ones.
base_sig <- sub("^normalizer sig +", "", grep("^normalizer sig", env, value = TRUE))
cur_sig  <- tryCatch(npmatch::np_normalize_signature(),
                     error = function(e) NA_character_)
if (is.na(cur_sig)) {
  say("!! npmatch::np_normalize_signature() unavailable -- 0b is not merged.")
  say("   Proceeding, but this gate cannot detect normalizer drift.")
} else if (!identical(base_sig, cur_sig)) {
  say("!! normalizer signature MISMATCH"); say("   baseline  %s", base_sig)
  say("   installed %s", cur_sig)
  stop("rebuild the baseline, or pin npmatch to the commit it was built with.")
} else say("normalizer signature matches: %s", cur_sig)
say("")

fail <- 0L
report <- function(label, d) {
  say("--- %s ---", label); print(d)
  if (!d$passed) fail <<- fail + 1L
  invisible(d)
}

if (GATE == "selftest") {
  # Baseline against itself: the harness must find nothing.
  for (f in list.files(BASE, pattern = "^benchmark-1k-.*\\.rds$", full.names = TRUE)) {
    d <- readRDS(f)
    report(sprintf("tiered self-compare: %s", basename(f)),
           md_compare_tiered(d, d))
    # and a negative control -- if perturbing a verdict does NOT fail, the
    # harness is not measuring anything
    p <- d; p$tier[1] <- if (as.character(p$tier[1]) == "YES") "NO" else "YES"
    neg <- md_compare_tiered(d, p)
    say("--- negative control (one tier flipped) ---")
    say("  detected: %s   cells differing: %d",
        if (!neg$passed) "YES" else "**NO -- harness is blind**", neg$n_cells_differ)
    if (neg$passed) fail <- fail + 1L
    say("")
  }
} else if (GATE == "phase1") {
  # Phase 1 (PLAN.md section 11): the BMF-only spec must reproduce pfmatch's
  # reference from the same strings - three zeros - and the 1k benchmark run on
  # it must be identical. Baseline: dev/BASELINE-2026-10 (build-baseline-2026-10.R).
  PFCODE <- Sys.getenv("PFMATCH_CODE"); PFIN <- Sys.getenv("PFMATCH_INPUTS")
  if (!nzchar(PFCODE) || !nzchar(PFIN)) stop("phase1 needs PFMATCH_CODE and PFMATCH_INPUTS")
  suppressWarnings(suppressMessages(devtools::load_all(PFCODE, quiet = TRUE)))
  big <- md_path("work", "baseline-2026-10")
  base_ref <- readRDS(file.path(big, "REF-active-raw.rds"))
  cols <- setdiff(readLines(file.path(BASE, "columns-reference-raw.txt")), ".id")

  spec <- md_spec(layers = "bmf_active", names = c("legal", "dba"), addresses = "mailing",
                  sources = "bmf", label = "active-legal")
  print(spec)
  con <- md_db(read_only = TRUE)
  t0 <- proc.time()[["elapsed"]]
  cmp <- md_compile(spec, con)
  md_db_close(con)
  say("compiled %s rows in %.0f s", format(nrow(cmp$reference), big.mark = ","),
      proc.time()[["elapsed"]] - t0)
  ref <- cmp$reference
  # county: matchdb fills it from census geocodes, np_map_bmf() leaves it empty.
  # It is blanked for the comparison and counted, not hidden.
  say("matchdb adds a county to %s rows; blanked for this gate",
      format(sum(nzchar(ref$county)), big.mark = ","))
  ref$county <- ""
  ref <- ref[, setdiff(names(ref), c("variant_class", "address_class", "layer"))]
  ref$.id <- NA_character_

  report("reference frame vs pfmatch's, same BMF strings",
         md_compare_frames(base_ref$reference, ref, cols,
                           key = c(".ein", "name_key", "street_key", "zip5")))
  for (s in c("name_freq", "token_idf")) {
    a <- cmp[[s]]; b <- base_ref[[s]]
    same <- identical(a[order(names(a))], b[order(names(b))])
    say("--- %s: %s (%s names) ---", s, if (same) "identical" else "DIFFERS", length(a))
    if (!same) fail <- fail + 1L
  }

  grants <- pf_read_grants(PFIN, pattern = "^1k_grants_.*\\.csv$")
  grants <- pf_recover_name_from_street(grants, verbose = FALSE)
  passes <- c(pf_staged_passes("lean", concat = TRUE), pf_recovery_passes(state = TRUE))
  bundle <- list(reference = ref, name_freq = cmp$name_freq, token_idf = cmp$token_idf,
                 ref_index = npmatch::np_ref_index(ref))
  m <- pf_match_grants(grants, bundle, passes = passes, recover = TRUE, verbose = FALSE)
  res <- as.data.frame(m$result); res <- res[order(res$.id), , drop = FALSE]
  rownames(res) <- NULL
  base_bench <- readRDS(file.path(BASE, "benchmark-1k-raw.rds"))
  report("1k benchmark on the compiled reference vs baseline", md_compare_tiered(base_bench, res))

  # Not a gate: what storing raw rather than processed BMF strings changes.
  proc <- readRDS(file.path(BASE, "benchmark-1k-processed.rds"))
  d <- md_compare_tiered(proc, base_bench)
  say("--- not a gate: raw BMF strings vs processed (pfmatch today) ---")
  print(rbind(processed = table(factor(proc$tier, c("YES", "MAYBE", "NO"))),
              raw = table(factor(base_bench$tier, c("YES", "MAYBE", "NO")))))
  say("  identities whose verdict or EIN differs: %d of %d", d$n_cells_differ, d$n_compared)
} else {
  stop("unknown MD_GATE: ", GATE, call. = FALSE)
}

hr()
if (fail == 0L) {
  say("GATE PASSED")
} else {
  say("GATE FAILED (%d check(s))", fail)
}
quit(save = "no", status = if (fail == 0L) 0L else 1L)
