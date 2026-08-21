#!/bin/sh
# Report what machine produced a measurement, as JSON on stdout.
#
# Standalone by design: no beacon, no jq, nothing but a POSIX shell and the
# kernel's own interfaces. An operator can read this before running it, which
# is not true of a 200 MiB binary, and it can be revised and re-published
# without a beacon release.
#
# The disk section is the point of this script. Naming a mount point is nearly
# useless: the benchmark's headline configuration bypasses the OS page cache
# specifically to put real disk I/O on the measured path, so the same number
# from an NVMe SSD, a spinning disk, an EBS volume and a network filesystem are
# four different results. Device-mapper and LVM are walked through to the
# physical members, because `rotational` and `model` on a dm-0 are meaningless.
#
# Every field is optional. Anything unreadable is recorded in "unavailable"
# with a reason rather than omitted silently -- a missing field and a field that
# needed root are different facts.
set -eu

DATA_DIR=${1:-.}

# ---------------------------------------------------------------- JSON output
# Hand-rolled because jq cannot be assumed and this must run anywhere.
esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
                         -e 's/\t/\\t/g' -e 's/\r/\\r/g' | tr -d '\000-\010\013\014\016-\037'
}
kv() { printf '    "%s": "%s",\n' "$1" "$(esc "$2")"; }

# Emits null rather than nothing when a value is absent or not a number. A bare
# `"field": ,` is invalid JSON and would take the whole report with it -- which
# is exactly what happened on aarch64, where /proc/cpuinfo has no "cpu cores"
# line, so awk succeeded with empty output and `|| echo 0` never fired.
kvnum() {
  case "$2" in
    "" | *[!0-9]*) printf '    "%s": null,\n' "$1" ;;
    *)             printf '    "%s": %s,\n' "$1" "$2" ;;
  esac
}

kvbool() {
  case "$2" in
    true | false) printf '    "%s": %s,\n' "$1" "$2" ;;
    *)            printf '    "%s": null,\n' "$1" ;;
  esac
}

UNAVAIL=""
note_unavailable() { UNAVAIL="$UNAVAIL$1: $2\n"; }

# Read a sysfs/procfs file, or record why not.
slurp() {
  if [ -r "$1" ]; then
    tr -d '\n' < "$1"
  else
    if [ -e "$1" ]; then
      note_unavailable "$1" "exists but not readable (try root)"
    else
      note_unavailable "$1" "absent on this kernel"
    fi
    printf ''
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ collectors
os_block() {
  printf '  "os": {\n'
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    kv distribution "${PRETTY_NAME:-${NAME:-unknown}}"
    kv distributionId "${ID:-unknown}"
    kv distributionVersion "${VERSION_ID:-unknown}"
  else
    kv distribution unknown
  fi
  kv kernel "$(uname -sr)"
  kv architecture "$(uname -m)"
  # The C library the *host* provides. Recorded because a distributable that
  # bundles its own is unaffected by it, and that is worth being able to show.
  if have ldd; then
    kv hostGlibc "$(ldd --version 2>/dev/null | head -1)"
  fi
  printf '    "_": null\n  },\n'
}

cpu_block() {
  printf '  "cpu": {\n'
  model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  [ -n "$model" ] || model=$(awk -F': ' '/^Model/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  kv model "${model:-unknown}"
  kvnum logicalCpus "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)"
  kvnum physicalCores "$(awk -F': ' '/^cpu cores/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo 0)"

  # These change measured timings materially, which is why they are here and
  # not in a footnote: a powersave governor and a performance one produce
  # different numbers on identical hardware.
  gov=$(slurp /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
  kv scalingGovernor "${gov:-unknown}"
  drv=$(slurp /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
  kv scalingDriver "${drv:-unknown}"

  if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    nt=$(slurp /sys/devices/system/cpu/intel_pstate/no_turbo)
    kvbool turboEnabled "$([ "$nt" = 0 ] && echo true || echo false)"
  elif [ -r /sys/devices/system/cpu/cpufreq/boost ]; then
    b=$(slurp /sys/devices/system/cpu/cpufreq/boost)
    kvbool turboEnabled "$([ "$b" = 1 ] && echo true || echo false)"
  fi

  smt=$(slurp /sys/devices/system/cpu/smt/control)
  [ -n "$smt" ] && kv smt "$smt"

  # Syscall-heavy work pays for these, and a benchmark of block application is
  # syscall-heavy.
  mit=""
  for f in /sys/devices/system/cpu/vulnerabilities/*; do
    [ -r "$f" ] || continue
    mit="$mit$(basename "$f")=$(tr -d '\n' < "$f"); "
  done
  [ -n "$mit" ] && kv mitigations "$mit"

  printf '    "_": null\n  },\n'
}

memory_block() {
  printf '  "memory": {\n'
  kvnum totalKb "$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  kvnum swapTotalKb "$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  # GHC manages its own heap; how the kernel backs it still matters.
  thp=$(slurp /sys/kernel/mm/transparent_hugepage/enabled)
  [ -n "$thp" ] && kv transparentHugepages "$thp"
  if have lscpu; then
    nodes=$(lscpu 2>/dev/null | awk -F': *' '/^NUMA node\(s\)/{print $2; exit}')
    [ -n "$nodes" ] && kvnum numaNodes "$nodes"
  fi
  printf '    "_": null\n  },\n'
}

virt_block() {
  printf '  "virtualisation": {\n'
  if have systemd-detect-virt; then
    kv detected "$(systemd-detect-virt 2>/dev/null || echo none)"
  else
    kv detected unknown
  fi
  # Cloud and hypervisor identity, which decides how to read disk figures.
  kv systemVendor "$(slurp /sys/class/dmi/id/sys_vendor)"
  kv productName "$(slurp /sys/class/dmi/id/product_name)"
  printf '    "_": null\n  },\n'
}

# Resolve a path to the whole physical devices backing it, walking
# device-mapper and md through to their members.
physical_devices() {
  name=$1
  if [ -d "/sys/class/block/$name/slaves" ] && [ -n "$(ls -A "/sys/class/block/$name/slaves" 2>/dev/null)" ]; then
    for s in "/sys/class/block/$name/slaves"/*; do
      physical_devices "$(basename "$s")"
    done
  elif [ -e "/sys/class/block/$name/partition" ]; then
    # A partition: its parent directory in sysfs is the whole disk.
    parent=$(basename "$(dirname "$(readlink -f "/sys/class/block/$name")")")
    echo "$parent"
  else
    echo "$name"
  fi
}

device_block() {
  disk=$1
  printf '      {\n'
  printf '        "name": "%s",\n' "$(esc "$disk")"
  printf '        "model": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/device/model")")"
  printf '        "vendor": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/device/vendor")")"
  rot=$(slurp "/sys/block/$disk/queue/rotational")
  case "$rot" in
    1) printf '        "rotational": true,\n' ;;
    0) printf '        "rotational": false,\n' ;;
    *) printf '        "rotational": null,\n' ;;
  esac
  sectors=$(slurp "/sys/block/$disk/size")
  [ -n "$sectors" ] && printf '        "sizeBytes": %s,\n' "$((sectors * 512))"
  printf '        "scheduler": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/queue/scheduler")")"
  printf '        "logicalBlockSize": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/queue/logical_block_size")")"
  printf '        "physicalBlockSize": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/queue/physical_block_size")")"
  printf '        "nrRequests": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/queue/nr_requests")")"
  printf '        "readAheadKb": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/queue/read_ahead_kb")")"
  # Write-back versus write-through dominates fsync-heavy work.
  printf '        "writeCache": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/queue/write_cache")")"
  printf '        "discardGranularity": "%s",\n' "$(esc "$(slurp "/sys/block/$disk/queue/discard_granularity")")"

  # NVMe: the PCIe link bounds achievable throughput regardless of the media.
  case "$disk" in
    nvme*)
      ctrl=${disk%%n[0-9]*}
      printf '        "nvmeFirmware": "%s",\n' "$(esc "$(slurp "/sys/class/nvme/$ctrl/firmware_rev")")"
      pci=$(readlink -f "/sys/block/$disk/device/device" 2>/dev/null || true)
      if [ -n "$pci" ] && [ -r "$pci/current_link_speed" ]; then
        printf '        "pcieLinkSpeed": "%s",\n' "$(esc "$(slurp "$pci/current_link_speed")")"
        printf '        "pcieLinkWidth": "%s",\n' "$(esc "$(slurp "$pci/current_link_width")")"
      fi
      ;;
  esac
  printf '        "_": null\n      }'
}

disk_block() {
  printf '  "dataDir": {\n'
  abs=$(CDPATH='' cd -- "$DATA_DIR" 2>/dev/null && pwd || echo "$DATA_DIR")
  kv path "$abs"

  src=""; fstype=""; opts=""
  if have findmnt; then
    src=$(findmnt -no SOURCE -T "$abs" 2>/dev/null || true)
    fstype=$(findmnt -no FSTYPE -T "$abs" 2>/dev/null || true)
    opts=$(findmnt -no OPTIONS -T "$abs" 2>/dev/null || true)
  else
    src=$(df -P "$abs" 2>/dev/null | awk 'NR==2{print $1}')
    note_unavailable findmnt "absent; filesystem type and mount options unknown"
  fi
  kv source "${src:-unknown}"
  kv filesystem "${fstype:-unknown}"
  # noatime, discard and barrier settings all change what the disk actually does.
  kv mountOptions "${opts:-unknown}"

  avail=$(df -Pk "$abs" 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "$avail" ] && kvnum availableKb "$avail"

  base=$(basename "${src:-}")
  printf '    "physicalDevices": [\n'
  first=1
  if [ -n "$base" ] && [ -e "/sys/class/block/$base" ]; then
    for d in $(physical_devices "$base" | sort -u); do
      [ "$first" = 1 ] || printf ',\n'
      device_block "$d"
      first=0
    done
  else
    note_unavailable "/sys/class/block/$base" "device not found in sysfs; is this a network or overlay filesystem?"
  fi
  printf '\n    ],\n'
  printf '    "_": null\n  },\n'
}

# ------------------------------------------------------------------------ main
printf '{\n'
printf '  "schemaVersion": 1,\n'
printf '  "collectedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '  "hostname": "%s",\n' "$(esc "$(hostname 2>/dev/null || echo unknown)")"
printf '  "collectedAsRoot": %s,\n' "$([ "$(id -u)" = 0 ] && echo true || echo false)"
os_block
cpu_block
memory_block
virt_block
disk_block
printf '  "unavailable": [\n'
if [ -n "$UNAVAIL" ]; then
  printf '%b' "$UNAVAIL" | sed '/^$/d' | sort -u | awk '
    NR>1 {printf ",\n"} {printf "    \"%s\"", $0} END {printf "\n"}'
fi
printf '  ]\n'
printf '}\n'
