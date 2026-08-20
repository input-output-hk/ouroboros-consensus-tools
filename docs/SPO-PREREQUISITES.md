# What an SPO's machine needs to run `glue`

The distributable of [ouroboros-leios#1048](https://github.com/input-output-hk/ouroboros-leios/issues/1048)
is a single executable file. This is the complete list of what it expects to
find on the machine that runs it, and what it brings with it.

Everything stated here is **enforced by CI** rather than asserted — see
[Keeping this honest](#keeping-this-honest). Where a claim has not yet been
tested, it is marked as such rather than presented as fact.

Last verified: see the `Glue distributable` workflow on the most recent run.

## Required on the host

| tool | why | if absent |
|---|---|---|
| POSIX `sh` | the artifact is a shell header with an archive appended | nothing runs |
| `tar`, `gzip` | unpacking that archive | refuses to unpack, and names the install command for your distribution |
| `coreutils` (`dd`, `mkdir`, `mv`, `rm`, `cat`, `printf`) | unpacking and pointing the bundled loader at itself | nothing runs |
| `awk`, `tail` | locating the archive inside the artifact | nothing runs |

That is the entire list for the current (phase 1) artifact.

**`tar` and `gzip` are not as universal as they look.** Every real
installation has them, including the Amazon Linux 2023 EC2 AMI — but the
`amazonlinux:2023` *container image* ships neither, and that was found only by
testing it. If you are running inside a minimal container:

```
dnf install -y tar gzip      # RHEL, Rocky, Amazon Linux
apt-get install -y tar gzip  # Debian, Ubuntu
apk add tar gzip             # Alpine
```

## Not required — these travel with the artifact

Listing these because each was, at some point, assumed to be present and
turned out not to be:

- **glibc, and its dynamic loader.** The binaries reference symbols up to
  `GLIBC_2.38`; RHEL 8 has 2.28, RHEL 9 and Amazon Linux 2023 have 2.34,
  Ubuntu 22.04 has 2.35. Relying on the host's C library would therefore fail
  on everything except Ubuntu 24.04 and newer, so glibc is bundled and the
  host's version does not matter.
- **`db-analyser`.** Pinned at build time; no nix, no network, no compiler.
- **GNU `time`.** A separate package on every distribution and frequently
  absent, and the shell's `time` is a builtin with no `-v`/`-o`. Where it is
  missing, peak-memory and I/O figures are silently *not collected*, which is
  worse than failing — so it is bundled.
- **`jq`.** Not in base on Debian, Ubuntu or RHEL, and beacon reshapes
  db-analyser's output through it. Bundled, and the launcher puts the bundled
  copy ahead of any host one on `PATH`.
- **`curl` and `unzip`.** curl is absent from Debian netinst and minimal
  container images; unzip is a separate package everywhere. Both bundled, along
  with a CA bundle — nixpkgs curl looks for certificates at a store path that
  does not exist on the target. Note the integrity guarantee does not rest on
  TLS: every fragment is checked against a sha256 baked into the release.
- **All shared libraries** the binaries need: `libstdc++`, `libgmp`, `libffi`,
  `libnuma`, `libgcc_s`, `liburing`, `libsodium`, `libblst`, `libsecp256k1`.
  This list is derived from the loader's own resolution at build time, not
  maintained by hand — `libnuma` was in the real closure while absent from
  every list written by hand.

## Tested platforms

x86_64 only. Every one of these has a glibc older than the `GLIBC_2.38` the
binaries require, which is the point: they demonstrate that the bundled glibc
makes the host's version irrelevant.

| distribution | glibc |
|---|---|
| `rockylinux:8` | 2.28 |
| `amazonlinux:2023` | 2.34 |
| `ubuntu:22.04` | 2.35 |
| `debian:12` | 2.36 |

Not yet tested: aarch64 of any kind, and darwin.

## Running it

```
./glue                      # the whole job: prepare, fetch, measure, report
```

That is all an SPO needs. It confirms before downloading, and refuses rather
than proceeding unattended — pass `--yes` for cron or scripts.

The steps are individually available for anyone who wants them:

```
./glue provision            # prepare ./glue-data (idempotent)
./glue fetch -l             # list available chain fragments
./glue fetch                # download and register one (~800 MiB)
./glue sysinfo              # hardware report as JSON on stdout
./glue benchmark            # measure a registered fragment
./glue report               # re-assemble the report from stored runs
./glue beacon ...           # run beacon directly (developer access)
```

Anything not named above — including a bare invocation and any leading option —
runs the whole job. Raw beacon access is explicit, via `glue beacon`, rather
than a fallthrough: deciding by inspecting arguments against beacon's own
subcommands would couple the launcher to a CLI it does not own.

Every one of these is a script inside the executable — nothing needs to be
downloaded alongside it. They are also attached to releases individually so
they can be read before being trusted, which is why they are shell rather than
compiled into `beacon`.

`provision` stages what beacon would otherwise obtain from `nix build` and the
GitHub API: the pinned db-analyser, its build plan, and its resolved commit.
Nothing reaches the network, and beacon itself is unmodified.

`benchmark` finishes by writing `glue-report-<host>-<utc>.json` into the data
directory. **That single file is what to send back.** It carries the
measurements, the machine they were taken on, and the exact db-analyser build
that took them — the on-disk figures cannot be interpreted without the hardware
alongside them, so the two travel together.

The db-analyser revision is fixed at build time, so `benchmark` supplies
`--rev` itself; it is not the operator's concern.

## Disk, memory and time

| | |
|---|---|
| artifact download | ~35 MiB |
| unpacked into `${GLUE_HOME:-~/.cache/glue}` | ~120 MiB |
| chain fragment, transient | ~800 MiB archive + ~1.2 GiB unpacked |
| **free disk needed** | **~2.5 GiB** |
| memory | the benchmark itself is the constraint, not the tool; see `beacon/docs/METHODOLOGY.md` |

The unpacked tree is **not** movable after first run: the bundled loader is
referenced by an absolute path that is written during extraction. Delete the
directory and re-run to relocate it.

`GLUE_HOME` must be short enough that `<GLUE_HOME>/<hash>/lib/<loader>` fits in
256 bytes. Extraction fails with that explanation rather than truncating.

## Not yet true

These are planned and **not** part of the current artifact. They will add host
requirements when they land:

- **fuller hardware detail.** `sysinfo` reports what the kernel exposes
  without help. `findmnt` sharpens the filesystem and mount-option fields,
  `systemd-detect-virt` the virtualisation one, and `lscpu` the NUMA count.
  Where they are absent the affected fields appear in the report's
  `unavailable` list with a reason rather than being silently omitted. Fields
  needing root are reported the same way.

## Keeping this honest

Every claim above that can be tested, is:

- the **tested platforms** table is the CI container matrix; a check fails if
  the two disagree, so neither can drift from the other
- the **bundled library list** is printed by the build, so an upstream
  addition shows up in the log rather than on someone's machine
- **`GLIBC_2.38`** is re-derivable with `readelf -V` over the payload binaries;
  if a compiler or dependency bump raises it, the container matrix is what
  notices
- the **`tar`/`gzip` requirement** is asserted by running the artifact in an
  image that lacks them and checking the error names the fix

When any of this changes, the workflow is the place it will be caught first.
Update this file in the same commit.
