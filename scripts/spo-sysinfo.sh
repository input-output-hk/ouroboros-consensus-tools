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

# Read a sysfs/procfs file into $SLURP, or set it empty and record why.
#
# Deliberately NOT usable as `x=$(slurp path)`: a command substitution runs in a
# subshell, so note_unavailable would append to that subshell's copy of UNAVAIL
# and the reason would be discarded. Every per-disk field used to be fetched
# that way, which meant an unreadable model, scheduler or write_cache vanished
# with no entry explaining itself -- and those are the fields the report exists
# for. Call it as a statement, then read $SLURP.
SLURP=""
slurp() {
  SLURP=""
  if [ -r "$1" ]; then
    SLURP=$(tr -d '\n' < "$1")
  elif [ -e "$1" ]; then
    note_unavailable "$1" "exists but not readable (try root)"
  else
    note_unavailable "$1" "absent on this kernel"
  fi
}

# One queue attribute of $disk. Reads $disk from the caller, which is why it
# lives beside device_block rather than being called from anywhere else.
queue_field() {
  slurp "/sys/block/$disk/queue/$2"
  printf '        "%s": "%s",\n' "$1" "$(esc "$SLURP")"
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
  slurp /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
  kv scalingGovernor "${SLURP:-unknown}"
  slurp /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
  kv scalingDriver "${SLURP:-unknown}"

  if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    slurp /sys/devices/system/cpu/intel_pstate/no_turbo
    if [ "$SLURP" = 0 ]; then kvbool turboEnabled true; else kvbool turboEnabled false; fi
  elif [ -r /sys/devices/system/cpu/cpufreq/boost ]; then
    slurp /sys/devices/system/cpu/cpufreq/boost
    if [ "$SLURP" = 1 ]; then kvbool turboEnabled true; else kvbool turboEnabled false; fi
  fi

  slurp /sys/devices/system/cpu/smt/control
  if [ -n "$SLURP" ]; then kv smt "$SLURP"; fi

  # Syscall-heavy work pays for these, and a benchmark of block application is
  # syscall-heavy.
  mit=""
  for f in /sys/devices/system/cpu/vulnerabilities/*; do
    [ -r "$f" ] || continue
    mit="$mit$(basename "$f")=$(tr -d '\n' < "$f"); "
  done
  if [ -n "$mit" ]; then kv mitigations "$mit"; fi

  printf '    "_": null\n  },\n'
}

memory_block() {
  printf '  "memory": {\n'
  kvnum totalKb "$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  kvnum swapTotalKb "$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  # GHC manages its own heap; how the kernel backs it still matters.
  slurp /sys/kernel/mm/transparent_hugepage/enabled
  if [ -n "$SLURP" ]; then kv transparentHugepages "$SLURP"; fi
  if have lscpu; then
    nodes=$(lscpu 2>/dev/null | awk -F': *' '/^NUMA node\(s\)/{print $2; exit}')
    if [ -n "$nodes" ]; then kvnum numaNodes "$nodes"; fi
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
  slurp /sys/class/dmi/id/sys_vendor;  kv systemVendor "$SLURP"
  slurp /sys/class/dmi/id/product_name; kv productName "$SLURP"
  printf '    "_": null\n  },\n'
}

# Resolve a mount to the kernel's name for the block device behind it.
#
# Not by taking basename of the mount source: that string is not a device name
# in most of the interesting cases, and the failure is silent --
#
#   LVM / dm-crypt   /dev/mapper/vg-root     basename "vg-root", not in sysfs
#   btrfs subvolume  /dev/sda2[/home]        basename "home]"
#   ZFS              rpool/home              basename "home"
#   NFS              srv:/export/home        basename "home"
#
# -- so an LVM machine, which is most of them, reported no disk at all. The
# device number does not have this problem: the kernel maintains
# /sys/dev/block/MAJ:MIN for every mount that has a block device behind it.
# Prints "<method> <kernel-name>" on success. The method travels in the output
# rather than a variable because this runs in a command substitution, where an
# assignment would be made in a subshell and lost.
resolve_block_device() {
  path=$1

  # 1. Device number. Handles dm, md, plain partitions and whole disks.
  majmin=""
  # --raw, and trimmed: without it findmnt right-aligns the column and emits
  # "   0:48 ", which turns the sysfs lookup into /sys/dev/block/   0:48  and
  # never matches. This path silently did nothing until it was tested against a
  # real mount.
  if have findmnt; then
    majmin=$(findmnt --raw -no MAJ:MIN -T "$path" 2>/dev/null |
      head -1 | tr -d '[:space:]')
  fi
  if [ -z "$majmin" ]; then
    # st_dev, which Linux packs as
    #   major = (dev >> 8) & 0xfff
    #   minor = (dev & 0xff) | ((dev >> 12) & ~0xff)
    stdev=$(stat -c '%d' "$path" 2>/dev/null || true)
    stdev=$(printf '%s' "$stdev" | tr -d '[:space:]')
    if [ -n "$stdev" ]; then
      majmin=$(awk -v d="$stdev" 'BEGIN {
        printf "%d:%d", int(d / 256) % 4096, (d % 256) + int(d / 1048576) * 256
      }')
    fi
  fi
  if [ -n "$majmin" ]; then
    target=$(readlink -f "/sys/dev/block/$majmin" 2>/dev/null || true)
    if [ -n "$target" ] && [ -d "$target" ]; then
      echo "device-number $(basename "$target")"
      return 0
    fi
  fi

  # 2. Some filesystems get an anonymous device number (major 0) even though a
  #    real block device backs them -- btrfs is the common one. Fall back to the
  #    source string, minus any subvolume suffix, resolved through any symlink
  #    (/dev/mapper/... points at /dev/dm-N).
  raw=$2
  case "$raw" in
    /dev/*)
      devpath=${raw%%[*}
      devpath=$(readlink -f "$devpath" 2>/dev/null || true)
      if [ -n "$devpath" ]; then
        name=$(basename "$devpath")
        if [ -d "/sys/class/block/$name" ]; then
          echo "source-path $name"
          return 0
        fi
      fi
      ;;
  esac

  return 1
}

# ZFS hides the disks behind a pool, so neither the device number nor the source
# names anything in sysfs. Ask zpool, which usually needs privileges on Linux --
# best effort, and said so rather than silently reporting nothing.
zfs_pool_devices() {
  pool=${1%%/*}
  have zpool || { note_unavailable "zpool" "absent; ZFS pool '$pool' members unknown"; return 1; }
  out=$(zpool status -LP "$pool" 2>/dev/null) || {
    note_unavailable "zpool status $pool" "failed (usually needs root on Linux); pool members unknown"
    return 1
  }
  printf '%s\n' "$out" | awk '/^\t  \/dev\// { print $1 }' | while read -r d; do
    n=$(basename "$(readlink -f "$d" 2>/dev/null || echo "$d")")
    if [ -d "/sys/class/block/$n" ]; then echo "$n"; fi
  done
}

# Resolve a path to the whole physical devices backing it, walking
# device-mapper and md through to their members.
physical_devices() {
  name=$1
  # Depth guard: device-mapper cannot realistically cycle, but a malformed
  # slaves link should fail rather than recurse until the shell gives out.
  depth=${2:-0}
  if [ "$depth" -gt 8 ]; then
    note_unavailable "/sys/class/block/$name" "device stack deeper than 8; stopped walking"
    return 0
  fi
  if [ -d "/sys/class/block/$name/slaves" ] && [ -n "$(ls -A "/sys/class/block/$name/slaves" 2>/dev/null)" ]; then
    for s in "/sys/class/block/$name/slaves"/*; do
      physical_devices "$(basename "$s")" "$((depth + 1))"
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

  # model and vendor are SCSI/NVMe attributes. virtio-blk and loop devices have
  # neither, so an empty string here is normal for those and the reason lands in
  # "unavailable" -- which only works because slurp is called as a statement.
  slurp "/sys/block/$disk/device/model";  model=$SLURP
  slurp "/sys/block/$disk/device/vendor"; vendor=$SLURP
  printf '        "model": "%s",\n' "$(esc "$model")"
  printf '        "vendor": "%s",\n' "$(esc "$vendor")"

  slurp "/sys/block/$disk/queue/rotational"
  case "$SLURP" in
    1) printf '        "rotational": true,\n' ;;
    0) printf '        "rotational": false,\n' ;;
    *) printf '        "rotational": null,\n' ;;
  esac

  slurp "/sys/block/$disk/size"
  case "$SLURP" in
    "" | *[!0-9]*) printf '        "sizeBytes": null,\n' ;;
    *)             printf '        "sizeBytes": %s,\n' "$((SLURP * 512))" ;;
  esac

  queue_field scheduler          scheduler
  queue_field logicalBlockSize   logical_block_size
  queue_field physicalBlockSize  physical_block_size
  queue_field nrRequests         nr_requests
  queue_field readAheadKb        read_ahead_kb
  # Write-back versus write-through dominates fsync-heavy work.
  queue_field writeCache         write_cache
  queue_field discardGranularity discard_granularity

  # NVMe: the PCIe link bounds achievable throughput regardless of the media.
  case "$disk" in
    nvme*)
      # nvme0n1 -> nvme0. Multipath names (nvme0c0n1) do not reduce this way,
      # so the controller lookup is allowed to miss rather than guess.
      ctrl=${disk%%n[0-9]*}
      slurp "/sys/class/nvme/$ctrl/firmware_rev"
      printf '        "nvmeFirmware": "%s",\n' "$(esc "$SLURP")"
      pci=$(readlink -f "/sys/block/$disk/device/device" 2>/dev/null || true)
      if [ -n "$pci" ]; then
        slurp "$pci/current_link_speed"
        printf '        "pcieLinkSpeed": "%s",\n' "$(esc "$SLURP")"
        slurp "$pci/current_link_width"
        printf '        "pcieLinkWidth": "%s",\n' "$(esc "$SLURP")"
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
  if [ -n "$avail" ]; then kvnum availableKb "$avail"; fi

  # The kernel device behind this mount, however it is named. Falls back to the
  # pool members for ZFS, which has no block device of its own.
  devs=""
  RESOLVED_VIA=none
  if resolved=$(resolve_block_device "$abs" "$src"); then
    RESOLVED_VIA=${resolved%% *}
    kernel_dev=${resolved#* }
    devs=$(physical_devices "$kernel_dev" | sort -u)
  elif [ "$fstype" = zfs ]; then
    devs=$(zfs_pool_devices "$src" | sort -u)
    if [ -n "$devs" ]; then RESOLVED_VIA=zfs-pool; fi
  fi

  # Which method found the device. Recorded because a silent fallback is
  # exactly what hid a dead primary path: findmnt pads its MAJ:MIN column, so
  # the device-number lookup never matched, and every case still resolved
  # through the source-path fallback. With this field a returned report shows
  # which path actually ran.
  kv resolvedVia "$RESOLVED_VIA"

  printf '    "physicalDevices": [\n'
  first=1
  for d in $devs; do
    [ "$first" = 1 ] || printf ',\n'
    device_block "$d"
    first=0
  done
  if [ "$first" = 1 ]; then
    # Say which filesystem, and whether this is expected. A network, overlay or
    # in-memory filesystem has no disk to describe; anything else here is a gap
    # worth reporting back.
    case "$fstype" in
      nfs|nfs4|cifs|smb3|fuse.sshfs|overlay|overlayfs|tmpfs|ramfs|9p|virtiofs)
        note_unavailable "dataDir.physicalDevices" \
          "$fstype has no backing block device; disk characteristics do not apply" ;;
      zfs)
        note_unavailable "dataDir.physicalDevices" \
          "zfs pool members could not be read; disk characteristics unknown" ;;
      *)
        note_unavailable "dataDir.physicalDevices" \
          "could not resolve a block device for '${src:-unknown}' (${fstype:-unknown filesystem})" ;;
    esac
  fi
  printf '\n    ],\n'
  printf '    "_": null\n  },\n'
}

# ------------------------------------------------------------------------ main
printf '{\n'
printf '  "schemaVersion": 1,\n'
printf '  "collectedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '  "hostname": "%s",\n' "$(esc "$(uname -n 2>/dev/null || hostname 2>/dev/null || echo unknown)")"
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
