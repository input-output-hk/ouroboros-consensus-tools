#!/bin/sh
# Acquire a chain fragment and register it with beacon.
#
# Version 1 of the abstract chain-synthesizer of ouroboros-leios#1048:
# degenerate, Praos-only, and not a synthesizer at all -- it downloads prebuilt
# fragments named by share/chains.tsv. Where they are hosted is therefore a
# table change rather than a code change.
#
# Three properties matter at ~800 MiB over a home connection:
#
#   resumable        curl --continue-at, so a dropped connection does not start
#                    over
#   verified         sha256 before use. A truncated or substituted archive would
#                    otherwise surface much later as an incomprehensible
#                    db-analyser failure, on someone else's machine
#   honest           an archive that turns out to be a web page is refused with
#                    that as the reason, which is how rate limiting and moved
#                    objects actually present themselves
#
# Because every fragment is checked against a hash baked into the release, the
# integrity guarantee does not rest on TLS.
set -eu

usage() {
  cat <<'EOF'
Usage: glue-fetch-chain.sh [-n CHAIN] [-d DATA_DIR] [-l]

  -n CHAIN     fragment to fetch (default: the first in the table)
  -d DATA_DIR  beacon data directory (default: ./glue-data, or $GLUE_DATA)
  -l           list the available fragments and exit
  -h, --help   this text
EOF
}

chain=""
data_dir=${GLUE_DATA:-./glue-data}
list_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    -n) chain=$2; shift 2 ;;
    -d) data_dir=$2; shift 2 ;;
    -l) list_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unexpected argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "${GLUE_ROOT:-}" ]; then
  self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  GLUE_ROOT=$(CDPATH='' cd -- "$self_dir/.." && pwd)
fi

table="$GLUE_ROOT/share/chains.tsv"
baseurl_file="$GLUE_ROOT/share/chains.baseurl"
[ -r "$table" ] || { echo "glue-fetch-chain: no fragment table at $table" >&2; exit 1; }
baseurl=$(sed -n '1p' "$baseurl_file")

if [ "$list_only" = 1 ]; then
  echo "available fragments:"
  awk -F'\t' '!/^#/ && NF>1 { printf "  %-18s %6.1f GiB archive  %s\n", $1, $4/1073741824, $8 }' "$table"
  exit 0
fi

[ -n "$chain" ] || chain=$(awk -F'\t' '!/^#/ && NF>1 {print $1; exit}' "$table")

row=$(awk -F'\t' -v n="$chain" '!/^#/ && $1==n {print; exit}' "$table")
if [ -z "$row" ]; then
  echo "glue-fetch-chain: no fragment named '$chain'. Available:" >&2
  awk -F'\t' '!/^#/ && NF>1 {print "  " $1}' "$table" >&2
  exit 1
fi

file=$(printf '%s' "$row" | cut -f2)
want_sha=$(printf '%s' "$row" | cut -f3)
want_bytes=$(printf '%s' "$row" | cut -f4)
db_dir=$(printf '%s' "$row" | cut -f5)
config=$(printf '%s' "$row" | cut -f6)
from_slot=$(printf '%s' "$row" | cut -f7)
descr=$(printf '%s' "$row" | cut -f8)

chain_dir="$data_dir/chain"
dest="$chain_dir/$chain"
archive="$chain_dir/$file"
mkdir -p "$chain_dir"

register() {
  # Written by hand rather than with jq: emitting JSON needs no parser, and one
  # fewer dependency on the path that has to work first.
  reg="$chain_dir/chain-register.json"
  tmp="$reg.tmp.$$"
  {
    printf '{\n'
    printf '  "%s": {\n' "$chain"
    printf '    "chHomeDir": "%s",\n' "$chain"
    printf '    "chDbDir": "%s",\n' "$db_dir"
    printf '    "chConfigFile": "%s",\n' "$config"
    printf '    "chFromSlot": %s,\n' "$from_slot"
    printf '    "chDescription": "%s"\n' "$descr"
    printf '  }\n'
    printf '}\n'
  } > "$tmp"
  mv "$tmp" "$reg"
  echo "registered $chain in $reg"
}

if [ -d "$dest" ]; then
  echo "fragment '$chain' is already unpacked at $dest"
  register
  exit 0
fi

echo "fetching $chain ($((want_bytes / 1048576)) MiB) from $baseurl"

# --continue-at resumes; --fail turns an HTTP error into a non-zero exit rather
# than a saved error page; --location follows the redirect a release download
# always involves.
curl --fail --location --continue-at - \
     --retry 3 --retry-delay 5 \
     --output "$archive" \
     "$baseurl/$file"

# A download that "succeeded" but produced something other than an archive is a
# rate-limit notice, a captive portal, or a moved object. Saying so beats failing
# later at unzip with a confusing message.
#
# The magic bytes are read as hex rather than raw: a zip begins PK\x03\x04 and
# contains nulls, which a command substitution strips while warning
# "ignored null byte in input" -- on every successful download.
magic=$(od -An -tx1 -N4 "$archive" 2>/dev/null | tr -d ' \n')
if [ "$magic" != "504b0304" ]; then
  echo "glue-fetch-chain: $baseurl/$file is not a zip archive." >&2
  # Nulls stripped before this reaches a substitution, for the same reason.
  head -c 200 "$archive" 2>/dev/null | tr -d '\000' | head -3 | sed 's/^/  | /' >&2
  case "$magic" in
    3c21444f|3c68746d|3c48544d)
      echo "  That is a web page: the link may have moved or be rate-limited." >&2 ;;
    *)
      echo "  Expected a zip (magic 504b0304), got $magic." >&2 ;;
  esac
  exit 1
fi

got_bytes=$(wc -c < "$archive" | tr -d ' ')
if [ "$got_bytes" != "$want_bytes" ]; then
  echo "glue-fetch-chain: $file is $got_bytes bytes, expected $want_bytes" >&2
  exit 1
fi

echo "verifying sha256"
got_sha=$(sha256sum "$archive" | cut -d' ' -f1)
if [ "$got_sha" != "$want_sha" ]; then
  echo "glue-fetch-chain: checksum mismatch for $file" >&2
  echo "  expected $want_sha" >&2
  echo "  actual   $got_sha" >&2
  echo "Refusing to benchmark an archive that is not the one this build pins." >&2
  rm -f "$archive"
  exit 1
fi

echo "unpacking"
staging="$dest.unpacking.$$"
rm -rf "$staging"
mkdir -p "$staging"
unzip -q "$archive" -d "$staging"

# An archive may or may not wrap its contents in a single top-level directory.
# Normalise either way, and do not leave the staging directory behind.
count=$(find "$staging" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
only=$(find "$staging" -mindepth 1 -maxdepth 1 | head -1)
if [ "$count" = 1 ] && [ -d "$only" ]; then
  mv "$only" "$dest"
  rmdir "$staging"
else
  mv "$staging" "$dest"
fi

# The archive is a second copy of something already large, and these machines
# are the ones short of disk.
rm -f "$archive"

register
echo "fragment ready at $dest"
