#!/usr/bin/env bash
# Upload the release to s3://nccs-efile/dev/matchdb/ in the Oct 23 layout, plus
# the maintainer copy. Databases first, manifests last, so a reader never sees a
# manifest whose md5 does not match its file.
set -euo pipefail
# Run from the repo root once the day's logs are in dev/verify/logs.
S3=s3://nccs-efile/dev/matchdb; D="${MATCHDB_DATA:?set MATCHDB_DATA}"; L=dev/verify/logs
DAY="${MD_RELEASE_DAY:-$(date +%Y-%m-%d)}"
t0=$(date +%s); say(){ echo "[$(( ($(date +%s)-t0)/60 )) min] $*"; }
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
say "logs"
aws s3 cp "$D/logs/build-matchdb.log" "$S3/logs/build.log" --only-show-errors
aws s3 cp "$L/build-ledger-$DAY.log" "$S3/logs/build-ledger.log" --only-show-errors
aws s3 cp "$L/check-build-$DAY.log" "$S3/logs/check.log" --only-show-errors
aws s3 cp "$L/phase1-gate-$DAY.log" "$S3/logs/phase1-gate-$DAY.log" --only-show-errors
aws s3 cp "$L/phase2-measure-$DAY.log" "$S3/logs/phase2-measure-$DAY.log" --only-show-errors
aws s3 cp "$L/publish-tiers-$DAY.log" "$S3/logs/publish.log" --only-show-errors
aws s3 cp "$L/compact-$DAY.log" "$S3/logs/compact.log" --only-show-errors
say "manifests"
aws s3 cp "$D/release/MANIFEST-full.json" "$S3/MANIFEST-full.json" --only-show-errors
aws s3 cp "$D/release/MANIFEST.json" "$S3/MANIFEST.json" --only-show-errors
say "uploaded"
