#!/bin/sh
# The whole job, in one command: prepare, fetch, benchmark, report.
#
# This is what `./glue` does with no arguments. The individual steps remain
# available for anyone who wants to drive them separately, but an SPO should not
# have to know that provisioning precedes fetching, or that the report is a
# separate artifact from the runs.
#
# It downloads roughly 800 MiB and needs about 2.5 GiB of free disk, so it
# confirms first when there is someone to ask. Non-interactive use must pass
# --yes: proceeding silently with a download that large because nobody was
# watching is worse than refusing.
set -eu

usage() {
  cat <<'EOF'
Usage: glue [options]

Runs the whole benchmark: prepares a data directory, downloads a chain
fragment, measures it in four configurations, and writes a report to send back.

  -d DATA_DIR  where to work (default: ./glue-data, or $GLUE_DATA)
  -n CHAIN     chain fragment to use (default: the first available)
  -y, --yes    do not ask before downloading
  --apply-only, --reapply-only
               restrict which apply modes are measured (default: both)
  -h, --help   this text

Individual steps, if you would rather drive them yourself:

  glue provision   prepare the data directory
  glue fetch -l    list the available chain fragments
  glue fetch       download and register one
  glue sysinfo     print a hardware report as JSON
  glue benchmark   measure a registered fragment
  glue report      re-assemble the report from stored runs

  glue beacon ...  run beacon directly (developer access)
EOF
}

data_dir=${GLUE_DATA:-./glue-data}
chain=""
assume_yes=0
mode_args=""

while [ $# -gt 0 ]; do
  case "$1" in
    -d) data_dir=$2; shift 2 ;;
    -n) chain=$2; shift 2 ;;
    -y|--yes) assume_yes=1; shift ;;
    --apply-only|--reapply-only) mode_args="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "glue: unexpected argument: $1" >&2
      echo >&2
      echo "If you meant a beacon subcommand, run it as: glue beacon $* " >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "${GLUE_ROOT:-}" ]; then
  self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  GLUE_ROOT=$(CDPATH='' cd -- "$self_dir/.." && pwd)
fi
export GLUE_ROOT

step() { printf '\n=== %s ===\n' "$1"; }

# Whether anything needs downloading decides both the confirmation and the disk
# check: a fragment already unpacked costs neither.
register="$data_dir/chain/chain-register.json"
needs_fetch=1
if [ -f "$register" ] && grep -q '"ch' "$register" 2>/dev/null; then
  needs_fetch=0
fi

if [ "$needs_fetch" = 1 ]; then
  # df -Pk on a path that does not exist yet fails, so ask about its parent.
  probe="$data_dir"
  while [ ! -d "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ]; do
    probe=$(dirname "$probe")
  done
  avail_kb=$(df -Pk "$probe" 2>/dev/null | awk 'NR==2{print $4}')
  need_kb=2621440   # ~2.5 GiB: archive plus unpacked fragment, plus headroom

  if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ]; then
    echo "glue: not enough free disk at $probe" >&2
    echo "  available: $((avail_kb / 1048576)) GiB" >&2
    echo "  needed:    about 2.5 GiB" >&2
    echo "  Use -d to work somewhere with more room." >&2
    exit 1
  fi

  if [ "$assume_yes" != 1 ]; then
    if [ -t 0 ]; then
      cat <<EOF
This will:
  * download a chain fragment (~800 MiB) into $data_dir
  * measure it in four configurations, which takes a while
  * write a report for you to send back

About 2.5 GiB of disk will be used. Continue? [y/N]
EOF
      read -r reply
      case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "aborted."; exit 1 ;;
      esac
    else
      echo "glue: this downloads ~800 MiB, and nothing is attached to confirm it." >&2
      echo "  Re-run with --yes to proceed." >&2
      exit 1
    fi
  fi
fi

step "preparing $data_dir"
"$GLUE_ROOT/scripts/glue-provision.sh" "$data_dir"

if [ "$needs_fetch" = 1 ]; then
  step "fetching a chain fragment"
  if [ -n "$chain" ]; then
    "$GLUE_ROOT/scripts/glue-fetch-chain.sh" -n "$chain" -d "$data_dir"
  else
    "$GLUE_ROOT/scripts/glue-fetch-chain.sh" -d "$data_dir"
  fi
else
  step "using the chain fragment already present"
fi

step "benchmarking"
# shellcheck disable=SC2086  # mode_args is one optional flag, deliberately split
if [ -n "$chain" ]; then
  "$GLUE_ROOT/scripts/glue-benchmark.sh" -n "$chain" -d "$data_dir" $mode_args
else
  "$GLUE_ROOT/scripts/glue-benchmark.sh" -d "$data_dir" $mode_args
fi
