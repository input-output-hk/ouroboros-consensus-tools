#!/bin/sh
# Collect everything the Leios team needs into one file to send back.
#
# The archive holds three kinds of thing, kept separate rather than merged:
#
#   runs/<slug>/run-NNN.json   beacon's own run files, byte for byte
#   sysinfo.json               the hardware report, standalone
#   provenance.json            what produced the measurements
#
# Copied verbatim, deliberately. An earlier version spliced all of this into one
# hand-assembled JSON document, which meant every field of the hardware report
# was load-bearing for the whole file: a numeric field that was empty on one
# architecture -- /proc/cpuinfo has no "cpu cores" line on ARM -- produced
# `"physicalCores": ,` and invalidated the entire report, measurements included.
# Separate files cannot do that to each other.
#
# It also means the run files arriving at the other end are the same bytes
# beacon wrote, so they can be fed straight back into `beacon summary` or
# `beacon compare` without anything having to un-transform them first.
set -eu

usage() {
  cat <<'EOF'
Usage: glue-report.sh [-d DATA_DIR] [-o OUTPUT]

  -d DATA_DIR  beacon data directory (default: ./glue-data, or $GLUE_DATA)
  -o OUTPUT    archive to write (default: glue-report-<host>-<utc>.zip in DATA_DIR)
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
    *) echo "glue-report: unexpected argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "${GLUE_ROOT:-}" ]; then
  self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  GLUE_ROOT=$(CDPATH='' cd -- "$self_dir/.." && pwd)
fi
export GLUE_ROOT

# Resolved by path, not by name: this script is runnable directly out of the
# extracted tree, where the launcher never set PATH.
ZIP="$GLUE_ROOT/bin/zip"
SYSINFO="$GLUE_ROOT/scripts/spo-sysinfo.sh"
for t in "$ZIP" "$SYSINFO"; do
  [ -x "$t" ] || { echo "glue-report: $t is missing from the payload" >&2; exit 1; }
done

# shellcheck disable=SC1091  # generated at build time
. "$GLUE_ROOT/share/pin.env"

# Find the run files first and refuse if there are none. The directory existing
# proves nothing -- provisioning creates it -- and an empty archive would look
# like a result.
runlist="${TMPDIR:-/tmp}/glue-report-runs.$$"
: > "$runlist"

if [ -d "$data_dir/run" ]; then
  for slug_dir in "$data_dir"/run/*; do
    [ -d "$slug_dir" ] || continue
    for f in "$slug_dir"/run-*.json; do
      [ -f "$f" ] || continue
      printf '%s\t%s\n' "$(basename "$slug_dir")" "$f" >> "$runlist"
    done
  done
fi

if [ ! -s "$runlist" ]; then
  rm -f "$runlist"
  echo "glue-report: no runs found under $data_dir/run" >&2
  echo "  run a benchmark first" >&2
  exit 1
fi

host=$(hostname 2>/dev/null || echo unknown)
safe_host=$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '-')
stamp=$(date -u +%Y%m%dT%H%M%SZ)
name="glue-report-$safe_host-$stamp"

[ -n "$output" ] || output="$data_dir/$name.zip"

# Absolute, because the archive is built from inside the staging directory.
case "$output" in
  /*) ;;
  *) output="$(CDPATH='' cd -- "$(dirname "$output")" && pwd)/$(basename "$output")" ;;
esac

staging="${TMPDIR:-/tmp}/$name.$$"
trap 'rm -rf "$staging" "$runlist"' EXIT INT TERM
mkdir -p "$staging/$name/runs"

# 1. The run files, unmodified.
samples=0
while IFS='	' read -r slug path; do
  mkdir -p "$staging/$name/runs/$slug"
  cp "$path" "$staging/$name/runs/$slug/$(basename "$path")"
  samples=$((samples + 1))
done < "$runlist"

# 2. The hardware report, regenerated so it describes the machine that is
#    sending this rather than whatever was recorded earlier.
"$SYSINFO" "$data_dir" > "$staging/$name/sysinfo.json"

# 3. Only what the run files cannot say for themselves.
#
#    beacon already records the analyzer commit and date, the host, the run
#    date, the chain, the backend, the apply mode and the consensus/ledger/plutus
#    manifest in every run file's `meta`, and the compiler appears in the run
#    directory name. Repeating any of that here would create a second copy that
#    can disagree with the first, so this file carries three things and no more:
#
#    reportVersion       how to read this archive; no run file can say that
#    assertionsDisabled  that db-analyser came from exesNoAsserts. beacon cannot
#                        know this -- it is a property of how the payload was
#                        built -- and it decides whether the numbers mean
#                        anything, since assertions sit on the measured path
#    analyzer.pinnedTo   what this *build* was pinned to, as opposed to what each
#                        run reports having used. If the two ever disagree the
#                        archive is self-inconsistent, and that is worth being
#                        able to see rather than having to trust
cat > "$staging/$name/provenance.json" <<EOF
{
  "reportVersion": 2,
  "analyzer": {
    "name": "db-analyser",
    "pinnedTo": "$ANALYZER_SHA",
    "assertionsDisabled": true
  }
}
EOF

# 4. One file. -X drops uid/gid and extra attributes so the same inputs give the
#    same archive; -r because the run files sit in per-configuration directories.
rm -f "$output"
(cd "$staging" && "$ZIP" -q -X -r "$output" "$name")

slugs=$(cut -f1 "$runlist" | sort -u | wc -l | tr -d ' ')
size=$(wc -c < "$output" | tr -d ' ')

cat <<EOF

report written to $output
  $slugs configuration(s), $samples run file(s), $((size / 1024)) KiB

  $name/
    runs/<configuration>/run-NNN.json   as beacon wrote them
    sysinfo.json                        the machine they were measured on
    provenance.json                     the db-analyser build that measured them

Send this single file back to the Leios team.
EOF
