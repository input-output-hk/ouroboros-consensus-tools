#!/bin/sh
# Run the benchmark matrix and print the summaries.
#
# This is the SPO-facing entry point. It exists as a script rather than a beacon
# subcommand for the same reason the hardware report does: it is a policy
# decision about *which* configurations to measure, it changes more often than
# beacon does, and it can be read before being trusted.
#
# What it runs mirrors what the Leios team has been running by hand: the
# in-memory backend, and the LSM backend with the OS page cache bypassed, each
# in apply (full validation) and reapply (trusted re-application) mode. Reapply
# is the mode on the block-diffusion critical path that
# ouroboros-leios#1048 is ultimately about.
#
# It also supplies --rev, which `beacon run` requires: this build pins one
# db-analyser, so the revision is not the operator's business.
set -eu

usage() {
  cat <<'EOF'
Usage: glue-benchmark.sh [-n CHAIN] [-d DATA_DIR] [--apply-only|--reapply-only]

  -n CHAIN     chain fragment to benchmark; defaults to the only registered one
  -d DATA_DIR  beacon data directory (default: ./glue-data, or $GLUE_DATA)
  --apply-only, --reapply-only
               restrict which apply modes are run (default: both)
  -h, --help   this text
EOF
}

chain=""
data_dir=${GLUE_DATA:-./glue-data}
modes="apply reapply"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) chain=$2; shift 2 ;;
    -d) data_dir=$2; shift 2 ;;
    --apply-only) modes="apply"; shift ;;
    --reapply-only) modes="reapply"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unexpected argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "${GLUE_ROOT:-}" ]; then
  self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  GLUE_ROOT=$(CDPATH='' cd -- "$self_dir/.." && pwd)
fi
export GLUE_ROOT

beacon="$GLUE_ROOT/bin/beacon"
[ -x "$beacon" ] || { echo "glue-benchmark: no beacon at $beacon" >&2; exit 1; }

"$GLUE_ROOT/scripts/glue-provision.sh" "$data_dir" >/dev/null

# shellcheck disable=SC1091  # generated at build time
. "$GLUE_ROOT/share/pin.env"

# With no -n, use the single registered fragment. Asking an operator to name
# the only chain there is would be ceremony; several is genuinely ambiguous.
if [ -z "$chain" ]; then
  chain=$(sed -n 's/^  "\([^"]*\)": {$/\1/p' "$data_dir/chain/chain-register.json" | head -2)
  count=$(printf '%s\n' "$chain" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    echo "glue-benchmark: no chain fragments registered in $data_dir/chain" >&2
    echo "  fetch one first, or pass -n" >&2
    exit 1
  elif [ "$count" -gt 1 ]; then
    echo "glue-benchmark: several fragments are registered; pick one with -n:" >&2
    printf '%s\n' "$chain" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "benchmarking the only registered fragment: $chain"
fi

run_one() {
  label=$1; shift
  echo
  echo "=== $label ==="

  # The slug a run lands under is derived from its parameters, but beacon is the
  # authority on it, so read it back from the path it reports rather than
  # recomputing it here and risking the two drifting.
  out=$("$beacon" --data-dir "$data_dir" run \
          --rev "$ANALYZER_SHA" --ghc "$ANALYZER_COMPILER" \
          -n "$chain" "$@" 2>&1) || {
    printf '%s\n' "$out" >&2
    echo "glue-benchmark: run failed ($label)" >&2
    return 1
  }
  printf '%s\n' "$out"

  slug=$(printf '%s\n' "$out" \
           | sed -n 's|.*run/\([^/]*\)/run-[0-9]*\.json.*|\1|p' | tail -1)
  if [ -z "$slug" ]; then
    echo "glue-benchmark: could not determine the run slug for $label" >&2
    return 1
  fi

  echo
  echo "--- summary: $label ---"
  "$beacon" --data-dir "$data_dir" summary "$slug"
}

for mode in $modes; do
  mode_flag=""
  [ "$mode" = reapply ] && mode_flag="--reapply"

  # shellcheck disable=SC2086  # mode_flag is deliberately unquoted (may be empty)
  run_one "in-memory ($mode)" --in-mem $mode_flag
  # shellcheck disable=SC2086
  run_one "LSM, page cache bypassed ($mode)" --lsm --lsm-no-cache $mode_flag
done

echo
echo "all configurations complete; results are under $data_dir/run"

# The measurements are only interpretable alongside the machine that produced
# them, so the report is assembled here rather than left as a step an operator
# has to know to take.
"$GLUE_ROOT/scripts/glue-report.sh" -d "$data_dir"
