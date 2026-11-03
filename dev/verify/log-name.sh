# The naming rule for dev/verify/logs, in one place, sourced by both sides.
#
# This file exists because the producer and the consumer of a log name used to
# agree only by memory. Each step's log was written by a redirect typed at the
# call site; release/upload.sh was the only reader, and it matched an exact name
# nothing in the repo produced. On 2026-11-02 the two stopped agreeing -- the
# logs were labelled with the npnormalize release under test and the upload
# wanted the day-only name -- and nothing could notice until the upload was
# already running. A shared definition cannot drift from itself.
#
# Paths are absolute, derived from this file, so a step can be run from any
# directory.

md_log_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
md_log_dir="$md_log_root/dev/verify/logs"

md_log_day(){ printf '%s' "${MD_RELEASE_DAY:-$(date +%Y-%m-%d)}"; }
md_log_label(){ printf '%s' "${MD_RELEASE_LABEL:-}"; }

# The one path a step writes to: the stem, the release label when the release
# has declared one, the day.
md_log_write_path(){ # md_log_write_path <stem>
  local label day
  label=$(md_log_label); day=$(md_log_day)
  printf '%s/%s%s-%s.log' "$md_log_dir" "$1" "${label:+-$label}" "$day"
}

# Every log a reader should accept for one step, as paths that exist, one per
# line. Two lines means the reader cannot tell which run it is looking at.
#
# With MD_RELEASE_LABEL the release has said which run is its own, so the
# labelled log wins and the bare name is the fallback -- a step that ran before
# the label was chosen still resolves. Without it, the bare name and any
# digit-labelled name are equally plausible and both are listed.
#
# A label begins with a digit because it names a release. That is not
# decoration: it is what keeps the stem `rebuild-normalizer` from also matching
# `rebuild-normalizer-install-0.1.8-2026-11-02.log`.
md_log_found(){ # md_log_found <stem>
  local stem=$1 label day f
  label=$(md_log_label); day=$(md_log_day)
  if [ -n "$label" ]; then
    for f in "$md_log_dir/$stem-$label-$day.log" "$md_log_dir/$stem-$day.log"; do
      if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
    done
    return 0
  fi
  for f in "$md_log_dir/$stem-$day.log" "$md_log_dir/$stem"-[0-9]*-"$day.log"; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; fi
  done
  return 0
}
