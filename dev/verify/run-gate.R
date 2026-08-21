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
  stop("phase1 gate needs md_compile(); not implemented yet.", call. = FALSE)
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
