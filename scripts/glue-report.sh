#!/bin/sh
# Collect everything the Leios team needs into one file.
#
# ouroboros-leios#1048 asks that it be easy to send reports back. The easiest
# artifact is a single file, so this gathers three things that are otherwise
# separate outputs:
#
#   what was measured    every stored run, with its per-slot datapoints, exactly
#                        as beacon wrote it
#   what measured it     the pinned db-analyser commit, its compiler, and the
#                        build plan behind it
#   where it ran         the hardware report -- without which the on-disk
#                        figures cannot be interpreted at all, since the
#                        headline configuration bypasses the page cache
#                        specifically to measure the disk
#
# No parsing is involved: beacon's run files and the hardware report are already
# JSON, and embedding JSON inside JSON is concatenation. That is why this needs
# no jq even though its output is a JSON document.
set -eu

usage() {
  cat <<'EOF'
Usage: glue-report.sh [-d DATA_DIR] [-o OUTPUT]

  -d DATA_DIR  beacon data directory (default: ./glue-data, or $GLUE_DATA)
  -o OUTPUT    file to write (default: glue-report-<host>-<utc>.json in DATA_DIR)
  -h, --help   this text
EOF
}

data_dir=${GLUE_DATA:-./glue-data}
output=""

while [ $# -gt 0 ]; do
  case "$1" in
    -d) data_dir=$2; shift 2 ;;
    -o) output=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unexpected argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "${GLUE_ROOT:-}" ]; then
  self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  GLUE_ROOT=$(CDPATH='' cd -- "$self_dir/.." && pwd)
fi
export GLUE_ROOT

# Collect the whole run files first, and refuse if there are none. The
# directory existing proves nothing -- provisioning creates it -- and an empty
# report would look like a result rather than an error.
#
# A run-NNN.json that is present but unparseable would corrupt the enclosing
# document, since this assembles by concatenation, so each is checked for a
# closing brace here rather than mid-write.
runlist="${TMPDIR:-/tmp}/glue-report-runs.$$"
: > "$runlist"
trap 'rm -f "$runlist"' EXIT INT TERM

if [ -d "$data_dir/run" ]; then
  for slug_dir in "$data_dir"/run/*; do
    [ -d "$slug_dir" ] || continue
    for f in "$slug_dir"/run-*.json; do
      [ -f "$f" ] || continue
      case "$(tail -c 3 "$f" | tr -d ' \n')" in
        *'}') printf '%s\t%s\n' "$(basename "$slug_dir")" "$f" >> "$runlist" ;;
        *) echo "glue-report: skipping truncated $f" >&2 ;;
      esac
    done
  done
fi

if [ ! -s "$runlist" ]; then
  echo "glue-report: no complete runs found under $data_dir/run" >&2
  echo "  run a benchmark first" >&2
  exit 1
fi

host=$(hostname 2>/dev/null || echo unknown)
stamp=$(date -u +%Y%m%dT%H%M%SZ)

if [ -z "$output" ]; then
  safe_host=$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '-')
  output="$data_dir/glue-report-$safe_host-$stamp.json"
fi

# shellcheck disable=SC1091  # generated at build time
. "$GLUE_ROOT/share/pin.env"

esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

tmp="$output.tmp.$$"

{
  printf '{\n'
  printf '  "reportVersion": 1,\n'
  printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "host": "%s",\n' "$(esc "$host")"

  printf '  "analyzer": {\n'
  printf '    "name": "db-analyser",\n'
  printf '    "ciCommitSHA1": "%s",\n' "$(esc "$ANALYZER_SHA")"
  printf '    "ciCommitDate": "%s",\n' "$(esc "$ANALYZER_DATE")"
  printf '    "compiler": "%s",\n' "$(esc "$ANALYZER_COMPILER")"
  printf '    "assertionsDisabled": true\n'
  printf '  },\n'

  # The hardware report is regenerated rather than read from a file, so it
  # always describes the machine that is sending the report.
  printf '  "system":\n'
  "$GLUE_ROOT/scripts/spo-sysinfo.sh" "$data_dir" | sed 's/^/    /'
  printf '  ,\n'

  printf '  "runs": {\n'
  first_slug=1
  # shellcheck disable=SC2013  # slugs cannot contain whitespace (see toSlug)
  for slug in $(cut -f1 "$runlist" | sort -u); do
    [ "$first_slug" = 1 ] || printf ',\n'
    printf '    "%s": [\n' "$(esc "$slug")"
    first_sample=1
    # shellcheck disable=SC2013  # fields are tab-separated paths, read by cut
    for f in $(awk -F'\t' -v s="$slug" '$1==s {print $2}' "$runlist" | sort); do
      [ "$first_sample" = 1 ] || printf ',\n'
      sed 's/^/      /' "$f"
      first_sample=0
    done
    printf '\n    ]'
    first_slug=0
  done
  printf '\n  }\n'
  printf '}\n'
} > "$tmp"

mv "$tmp" "$output"

size=$(wc -c < "$output" | tr -d ' ')
runs=$(cut -f1 "$runlist" | sort -u | wc -l | tr -d ' ')
samples=$(wc -l < "$runlist" | tr -d ' ')

cat <<EOF

report written to $output
  $runs configuration(s), $samples sample(s), $((size / 1024)) KiB

Send this single file back to the Leios team. It contains the measurements, the
machine they were taken on, and the exact db-analyser build that took them.
EOF
