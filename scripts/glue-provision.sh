#!/bin/sh
# Prepare a beacon data directory so `beacon run` needs neither nix nor network.
#
# beacon normally obtains db-analyser by shelling out to `nix build` and its
# commit metadata from the GitHub API. Neither is available to a distributed
# build, but neither is reached if what they would have produced is already in
# place. This script puts it there. beacon itself is unmodified.
#
# Three things are staged, matching what shellNixBuildVersion and
# BeaconLoadCommit look for:
#
#   bin/<sha9>-<compiler>            symlink to a directory holding
#                                    bin/db-analyser. It has to be a *symlink*:
#                                    the code readlinks it unconditionally and
#                                    treats failure as fatal.
#   bin/<sha9>-<compiler>.plan-json  directory holding plan.json, read to record
#                                    which package versions produced a run.
#   rev-cache.json                   the resolved commit, consulted before the
#                                    network whenever --rev is >= 7 hex chars
#                                    and uniquely prefixes an entry.
#
# Idempotent: safe to run before every benchmark.
set -eu

usage() {
  cat <<'EOF'
Usage: glue-provision.sh [DATA_DIR]

  DATA_DIR   beacon data directory to prepare (default: ./glue-data,
             or $GLUE_DATA if set)

Reads the payload it belongs to from $GLUE_ROOT, or infers it from this
script's location.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# Where the payload lives. GLUE_ROOT is set by the launcher; fall back to the
# parent of this script so the script also works when invoked directly.
if [ -z "${GLUE_ROOT:-}" ]; then
  self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  GLUE_ROOT=$(CDPATH='' cd -- "$self_dir/.." && pwd)
fi

DATA_DIR=${1:-${GLUE_DATA:-./glue-data}}

for f in share/pin.env share/plan.json analyzer/bin/db-analyser; do
  [ -e "$GLUE_ROOT/$f" ] || {
    echo "glue-provision: $GLUE_ROOT/$f is missing; is GLUE_ROOT correct?" >&2
    exit 1
  }
done

# shellcheck disable=SC1091  # generated at build time
. "$GLUE_ROOT/share/pin.env"

sha9=$(printf '%s' "$ANALYZER_SHA" | cut -c1-9)
tag="$sha9-$ANALYZER_COMPILER"

mkdir -p "$DATA_DIR/bin" "$DATA_DIR/chain" "$DATA_DIR/run"

# The symlink beacon will readlink and look inside.
ln -sfn "$GLUE_ROOT/analyzer" "$DATA_DIR/bin/$tag"

# The build plan, in the directory shape mkManifest expects.
mkdir -p "$DATA_DIR/bin/$tag.plan-json"
cp -f "$GLUE_ROOT/share/plan.json" "$DATA_DIR/bin/$tag.plan-json/plan.json"

# The resolved commit, so BeaconLoadCommit never reaches for the network.
# Written by hand rather than with jq: this must work before anything is on
# PATH, and the shape is two fields.
cat > "$DATA_DIR/rev-cache.json" <<EOF
[{"ciCommitDate":"$ANALYZER_DATE","ciCommitSHA1":"$ANALYZER_SHA"}]
EOF

# An empty register is valid and keeps beacon from warning about a missing
# file; the fetch step fills it in.
[ -e "$DATA_DIR/chain/chain-register.json" ] || echo '{}' > "$DATA_DIR/chain/chain-register.json"

cat <<EOF
provisioned $DATA_DIR
  analyzer   $ANALYZER_SHA ($ANALYZER_COMPILER)
  staged as  bin/$tag -> $GLUE_ROOT/analyzer
  plan       bin/$tag.plan-json/plan.json
  rev-cache  rev-cache.json
EOF
