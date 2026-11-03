#!/usr/bin/env bash
# Run one release step and write its log where release/upload.sh looks for it.
#
#   bash dev/verify/run-step.sh check-build -- Rscript dev/check-build.R
#   MD_GATE=phase1 MD_BASELINE=dev/BASELINE-2026-10 \
#     bash dev/verify/run-step.sh phase1-gate -- Rscript dev/verify/run-gate.R
#
# The stem is given rather than derived, because a step's log is not named after
# its script: run-gate.R writes phase1-gate when MD_GATE=phase1.
#
# The log path does not depend on where this is run from, but the step may: the
# dev scripts call pkgload::load_all("."), so run them from the repo root.
#
# Why a wrapper and not a sink() inside each R script: the log has to carry
# stderr and survive a crash. R's sink(split = TRUE) tees stdout but
# sink(type = "message") cannot split, so warnings and errors would go either
# only to the log -- invisible to whoever is watching a 54-minute derive -- or
# only to the console, which loses the most important thing in the record. A
# pipe through tee gets stdout, stderr and an Rscript crash, and the console
# still sees all of it live.
#
# This does not make the artifact unavoidable; it makes it uniform, with one
# stem to get right instead of a path. What catches a log that was never written
# is release/upload.sh's preflight (MD_PREFLIGHT_ONLY=1), which reads the same
# naming rule from log-name.sh.
set -uo pipefail                 # not -e: the step's own status is the result
. "$(dirname "${BASH_SOURCE[0]}")/log-name.sh"

if [ $# -lt 3 ] || [ "$2" != "--" ]; then
  echo "usage: run-step.sh <stem> -- <command> [args...]" >&2
  exit 2
fi
stem=$1; shift 2

out=$(md_log_write_path "$stem")
mkdir -p "$md_log_dir"
if [ -e "$out" ]; then
  # One log is the record of one run. Overwriting it is how 2026-11-02 would
  # have lost the record of the 0.1.6 rebuild that was killed and restarted --
  # the collision that made MD_RELEASE_LABEL necessary in the first place.
  echo "run-step.sh: $out already exists." >&2
  echo "  It is the record of a run that has already happened. Set" >&2
  echo "  MD_RELEASE_LABEL for this run, or move that file aside." >&2
  exit 1
fi

# %q, not $*: the header is provenance, and "bash -c echo a; echo b" does not
# say which of those were one argument.
cmd=$(printf '%q ' "$@")
echo "run-step.sh: $cmd"
echo "run-step.sh: -> $out"
{ printf '# %s: %s\n' "$stem" "$cmd"
  printf '# started %s\n\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"; } > "$out"
"$@" 2>&1 | tee -a "$out"
st=${PIPESTATUS[0]}
printf '\n# exit %s at %s\n' "$st" "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$out"
echo "run-step.sh: exit $st, log $out"
exit "$st"
