#!/usr/bin/env bash
# Imports an arbitrary number of chain fragments (zipped, one per chain,
# plus a chain-register.json fragment describing them) received from
# someone else, merges them into ./beacon-data/chain/, then runs the
# on-disk LSM/no-page-cache benchmark (no heap limit) against each
# imported chain and prints its summary.
#
# Requires `beacon`, `jq`, and `unzip` on PATH (the `beacon-import-and-benchmark`
# flake package wraps this script with all three provided).
#
# Expects <input-dir> to contain:
#   - any number of "<chain-name>.zip" archives (0 or more may be present
#     on a given run), each unzipping to that chain's home directory
#     (config.json, genesis files, db/, ...)
#   - a "chain-register.json" fragment, in beacon's chain-register format,
#     with an entry for each zip's chain name (it may also list chains not
#     shipped this time; those are merged in but not benchmarked here)
#
# Which chains get imported/benchmarked is driven by which .zip files are
# actually present in <input-dir>, not by a fixed count.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-received-chains-lsmnc-benchmark.sh <input-dir> [--rev REF] [--data-dir DIR] [--dry-run]

  <input-dir>      Directory containing "<chain-name>.zip" archives and a
                    "chain-register.json" fragment for those chains.
  --rev REF         db-analyser (ouroboros-consensus) commit/tag/branch to
                    benchmark. Default: 0ebd397d
  --data-dir DIR    beacon data directory. Default: ./beacon-data
  --dry-run         Perform the import and chain-register.json merge for
                    real, but only print the beacon commands instead of
                    executing them.
  -h, --help        Show this help
EOF
}

rev="0ebd397d"
data_dir="./beacon-data"
input_dir=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rev) rev="$2"; shift 2 ;;
    --data-dir) data_dir="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$input_dir" ]]; then
        input_dir="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; usage; exit 1
      fi
      ;;
  esac
done

if [[ -z "$input_dir" ]]; then
  echo "Missing <input-dir>" >&2; usage; exit 1
fi
if [[ ! -d "$input_dir" ]]; then
  echo "Not a directory: $input_dir" >&2; exit 1
fi

for tool in beacon jq unzip; do
  if ! command -v "$tool" >/dev/null; then
    echo "Missing required tool on PATH: $tool" >&2
    exit 1
  fi
done

incoming_register="$input_dir/chain-register.json"
if [[ ! -f "$incoming_register" ]]; then
  echo "Missing $incoming_register" >&2; exit 1
fi

chain_dir="$data_dir/chain"
register="$chain_dir/chain-register.json"
mkdir -p "$chain_dir"

log() { echo "=== $* ===" >&2; }

log "Merging chain-register.json"
if [[ -f "$register" ]]; then
  cp "$register" "$register.bak"
  jq -s '.[0] * .[1]' "$register" "$incoming_register" > "$register.tmp"
else
  cp "$incoming_register" "$register.tmp"
fi
mv "$register.tmp" "$register"
jq empty "$register"
log "chain-register.json now has: $(jq -r 'keys | join(", ")' "$register")"

log "Importing chain fragments from $input_dir"
mapfile -t zip_files < <(find "$input_dir" -maxdepth 1 -name '*.zip')
if [[ ${#zip_files[@]} -eq 0 ]]; then
  echo "No .zip archives found in $input_dir" >&2; exit 1
fi

chain_names=()
for zip_file in "${zip_files[@]}"; do
  name="$(basename "$zip_file" .zip)"

  if ! jq -e --arg n "$name" 'has($n)' "$register" >/dev/null; then
    echo "Warning: $zip_file has no matching entry in chain-register.json, skipping import" >&2
    continue
  fi

  dest="$chain_dir/$name"
  if [[ -e "$dest" ]]; then
    echo "Warning: $dest already exists, leaving it as-is (not re-importing)" >&2
    chain_names+=("$name")
    continue
  fi

  log "Unzipping $zip_file"
  tmp="$(mktemp -d)"
  unzip -q "$zip_file" -d "$tmp"
  find "$tmp" -name '__MACOSX' -type d -exec rm -rf {} + 2>/dev/null || true
  find "$tmp" -name '._*' -type f -delete

  # A zip may wrap its contents in a single top-level directory, or not.
  # Normalize to $dest either way.
  mapfile -t entries < <(find "$tmp" -mindepth 1 -maxdepth 1)
  if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
    mv "${entries[0]}" "$dest"
    rmdir "$tmp"
  else
    mv "$tmp" "$dest"
  fi

  chain_names+=("$name")
done

if [[ ${#chain_names[@]} -eq 0 ]]; then
  echo "No chains were imported, nothing to benchmark" >&2; exit 1
fi

for name in "${chain_names[@]}"; do
  if [[ "$dry_run" -eq 1 ]]; then
    log "[dry-run] would run: beacon --data-dir $data_dir run --rev $rev -n $name --lsm --lsm-no-cache"
    log "[dry-run] would run: beacon --data-dir $data_dir summary <resulting-slug>"
    continue
  fi

  log "Running LSM no-cache benchmark (no heap limit) for '$name'"
  out="$(beacon --data-dir "$data_dir" run --rev "$rev" -n "$name" --lsm --lsm-no-cache 2>&1)"
  echo "$out" >&2

  slug="$(echo "$out" | grep -oE 'run/[^/]+/run-[0-9]+\.json' | sed -E 's#run/([^/]+)/run-.*#\1#' | tail -n1)"
  if [[ -z "$slug" ]]; then
    echo "Could not determine run slug for '$name' from beacon's output, skipping summary" >&2
    continue
  fi

  log "Summary for $slug"
  beacon --data-dir "$data_dir" summary "$slug"
done
