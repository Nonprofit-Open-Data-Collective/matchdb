#!/usr/bin/env bash
# Upload the release to s3://nccs-efile/dev/matchdb/ in the Oct 23 layout, plus
# the maintainer copy. Databases first, manifests last, so a reader never sees a
# manifest whose md5 does not match its file.
set -euo pipefail
# Run from the repo root once the day's logs are in dev/verify/logs.
S3=s3://nccs-efile/dev/matchdb; D="${MATCHDB_DATA:?set MATCHDB_DATA}"; L=dev/verify/logs
DAY="${MD_RELEASE_DAY:-$(date +%Y-%m-%d)}"
t0=$(date +%s); say(){ echo "[$(( ($(date +%s)-t0)/60 )) min] $*"; }

# ---------------------------------------------------------------- the day's logs
# Each step's log is written by a redirect typed at the call site, so its name is
# a convention and nothing in the repo produces it. The 2026-11-02 release
# labelled every log with the npnormalize release under test
# (publish-tiers-0.1.8-2026-11-02.log), because two normalizer rebuilds ran that
# day and the bare name would have overwritten the first one's record. The label
# was the right instinct and the day-only name is the part that is wrong, so the
# files on disk are the authority here rather than a name spelled out below.
#
# A label must begin with a digit, because it names a release. That is not
# decoration: it is what keeps the stem `rebuild-normalizer` from also matching
# `rebuild-normalizer-install-0.1.8-2026-11-02.log`. Two matches are an error
# rather than a coin toss, since picking the wrong one publishes a log that
# describes a different run.
#
# Each candidate is tested with -f rather than left to nullglob, which discards
# only a pattern that HAS glob characters: "$L/$stem-$DAY.log" is a literal word
# and survives however little it exists, so relying on nullglob made every stem
# look ambiguous.
#
# Two runs in one day cannot be told apart by their names, whatever they are
# labelled -- 2026-11-02 holds an abandoned 0.1.6 rebuild as well as the 0.1.8
# one that produced the release. So where a release knows its own label it says
# so in MD_RELEASE_LABEL, and the labelled log wins over the bare name; a stem
# whose step did not carry the label still resolves, because the bare name is
# the second candidate. Without it there is nothing to choose on, and two
# candidates stay an error.
LABEL="${MD_RELEASE_LABEL:-}"
PICK=""
pick(){ # pick <stem>; sets PICK to the one match, "" if none; fails if two
  local stem=$1 f hits=()
  PICK=""
  if [ -n "$LABEL" ]; then
    for f in "$L/$stem-$LABEL-$DAY.log" "$L/$stem-$DAY.log"; do
      if [ -f "$f" ]; then PICK=$f; return 0; fi
    done
    return 0
  fi
  for f in "$L/$stem-$DAY.log" "$L/$stem"-[0-9]*-"$DAY.log"; do
    if [ -f "$f" ]; then hits+=("$f"); fi
  done
  if [ "${#hits[@]}" -gt 1 ]; then PICK="${hits[*]}"; return 1; fi
  if [ "${#hits[@]}" -eq 1 ]; then PICK="${hits[0]}"; fi
  return 0
}

# ------------------------------------------------------------------- preflight
# Nothing is uploaded until the whole set resolves. Before this, a missing log
# was discovered at the logs step -- after both databases, the bundles and
# publish/latest.json were already up, and before the manifests. That window is
# the damaging one: the new database then sits under the PREVIOUS manifest, and
# a reader who fetches it fails the md5 comparison .md_download() makes ("does
# not match its recorded md5; not kept"), so the published release is broken
# rather than merely stale until the manifests land. Manifests-last protects a
# reader from a manifest promising a file that is not there yet; it does nothing
# about a file that arrives ahead of its manifest.
#
# Set MD_PREFLIGHT_ONLY=1 to run these checks and stop. That costs nothing and
# can be done while the release is still being built.
problems=(); declare -A LOG=()
req(){ [ -e "$1" ] || problems+=("missing     $1"); }

B=$(sed -n 's/.*"build": *"\([^"]*\)".*/\1/p' "$D/tranches/latest.json" 2>/dev/null || true)

req "$D/release/MATCHDB_slim.duckdb"
req "$D/db/MATCHDB.duckdb"
req "$D/release/MANIFEST.json"
req "$D/release/MANIFEST-full.json"
req "$D/publish/latest.json"
req "$D/tranches/latest.json"
if [ -n "$B" ]; then req "$D/tranches/$B"
else problems+=("unreadable  build in $D/tranches/latest.json"); fi

# The gate logs the release cannot be published without.
for stem in check-build phase1-gate phase2-measure publish-tiers; do
  if ! pick "$stem"; then problems+=("ambiguous   $stem: $PICK"); continue; fi
  if [ -z "$PICK" ]; then
    problems+=("missing     $L/$stem-$DAY.log (or $stem-${LABEL:-<release>}-$DAY.log)")
  else LOG[$stem]=$PICK; fi
done
# The rest exist only for the step that actually ran: a ledger build, a
# normalizer rebuild, a compaction. Compaction in particular is not an
# every-release step -- compact.R refuses to run while the previous release's
# MATCHDB.precompact.duckdb is still on disk -- so requiring its log, as this
# script used to, failed releases that were correct.
#
# Absent is fine here; ambiguous is not. A log that is optional is still a
# record of one particular run, and publishing the wrong one of two is worse
# than publishing neither.
for stem in build-ledger rebuild-normalizer rebuild-normalizer-install compact; do
  if ! pick "$stem"; then problems+=("ambiguous   $stem: $PICK"); continue; fi
  if [ -n "$PICK" ]; then LOG[$stem]=$PICK; fi
done

# A stale manifest is the same failure from the other side: the database was
# rebuilt and the manifest still describes its predecessor. size_bytes catches
# that instantly. The md5 is the authoritative comparison but costs minutes over
# 44 GB, and manifest.R has just computed it over these same files.
chk(){ # chk <manifest> <database>
  local want have
  [ -e "$1" ] && [ -e "$2" ] || return 0
  want=$(sed -n 's/.*"size_bytes": *\([0-9]*\).*/\1/p' "$1")
  have=$(wc -c < "$2" | tr -d ' ')
  [ "$want" = "$have" ] ||
    problems+=("stale       $(basename "$1") says size_bytes $want, $(basename "$2") is $have")
}
chk "$D/release/MANIFEST.json" "$D/release/MATCHDB_slim.duckdb"
chk "$D/release/MANIFEST-full.json" "$D/db/MATCHDB.duckdb"

if [ "${#problems[@]}" -gt 0 ]; then
  printf 'upload.sh: nothing uploaded. %d problem(s) for DAY=%s%s:\n' \
    "${#problems[@]}" "$DAY" "${LABEL:+ MD_RELEASE_LABEL=$LABEL}" >&2
  printf '  %s\n' "${problems[@]}" >&2
  if [ -z "$LABEL" ] && printf '%s\n' "${problems[@]}" | grep -q '^ambiguous'; then
    echo "  -- set MD_RELEASE_LABEL to the release these logs belong to" >&2
  fi
  exit 1
fi
say "preflight clear${LABEL:+, label $LABEL}, ${#LOG[@]} logs resolved"
printf '%s\n' "${!LOG[@]}" | sort | while read -r stem; do echo "    $stem -> ${LOG[$stem]}"; done
[ -n "${MD_PREFLIGHT_ONLY:-}" ] && { say "preflight only, stopping"; exit 0; }

# ---------------------------------------------------------------------- upload
say "user copy";        aws s3 cp "$D/release/MATCHDB_slim.duckdb" "$S3/MATCHDB.duckdb" --only-show-errors
say "maintainer copy";  aws s3 cp "$D/db/MATCHDB.duckdb" "$S3/MATCHDB-full.duckdb" --only-show-errors
say "pins"
for f in "$D"/sources/*/*/PIN.dcf; do
  v=$(basename "$(dirname "$f")"); s=$(basename "$(dirname "$(dirname "$f")")")
  aws s3 cp "$f" "$S3/pins/${s}__${v}.dcf" --only-show-errors
  if [ -f "$(dirname "$f")/FILES.csv" ]; then aws s3 cp "$(dirname "$f")/FILES.csv" "$S3/pins/${s}__${v}.files.csv" --only-show-errors; fi
done
say "bundles"
aws s3 sync "$D/publish" "$S3/publish" --exclude "latest.json" --only-show-errors
aws s3 cp "$D/publish/latest.json" "$S3/publish/latest.json" --only-show-errors
# the tranche build named by tranches/latest.json, then the pointer itself
say "tranches $B"
aws s3 sync "$D/tranches/$B" "$S3/tranches/$B" --only-show-errors
aws s3 cp "$D/tranches/latest.json" "$S3/tranches/latest.json" --only-show-errors
say "logs"
# The published names carry no label: a reader wants the current check.log, not
# a file named after the release that produced it.
put(){ if [ -n "$1" ]; then aws s3 cp "$1" "$2" --only-show-errors; else echo "  (no $3)"; fi; }
put "${LOG[build-ledger]:-}"               "$S3/logs/build-ledger.log"                    "build-ledger log"
put "${LOG[rebuild-normalizer]:-}"         "$S3/logs/rebuild-normalizer-$DAY.log"         "rebuild-normalizer log"
put "${LOG[rebuild-normalizer-install]:-}" "$S3/logs/rebuild-normalizer-install-$DAY.log" "rebuild-normalizer-install log"
put "${LOG[compact]:-}"                    "$S3/logs/compact.log"                         "compact log"
# not day-keyed: the build log is whatever the last full build left behind
bm=""; if [ -f "$D/logs/build-matchdb.log" ]; then bm="$D/logs/build-matchdb.log"; fi
put "$bm" "$S3/logs/build.log" "$D/logs/build-matchdb.log"
aws s3 cp "${LOG[check-build]}"    "$S3/logs/check.log"               --only-show-errors
aws s3 cp "${LOG[phase1-gate]}"    "$S3/logs/phase1-gate-$DAY.log"    --only-show-errors
aws s3 cp "${LOG[phase2-measure]}" "$S3/logs/phase2-measure-$DAY.log" --only-show-errors
aws s3 cp "${LOG[publish-tiers]}"  "$S3/logs/publish.log"             --only-show-errors
say "manifests"
aws s3 cp "$D/release/MANIFEST-full.json" "$S3/MANIFEST-full.json" --only-show-errors
aws s3 cp "$D/release/MANIFEST.json" "$S3/MANIFEST.json" --only-show-errors
say "uploaded"
