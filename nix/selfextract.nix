# Wrap a relocatable payload into one executable file.
#
# A POSIX shell header with a gzipped tar appended. First run unpacks into a
# cache directory, points each binary's interpreter at the unpacked loader,
# and execs beacon; later runs skip straight to the exec.
#
# tar and gzip are the only host tools required. That is a deliberate line:
# they are present on every distribution in practice, unlike jq, unzip or a
# GNU `time`. Bundling a tar to unpack the archive containing the tar is not a
# solvable problem.
{
  pkgs,
  lib,
}: let
  header = pkgs.writeText "glue-header.sh" ''
    #!/bin/sh
    # Self-extracting distributable of ouroboros-leios#1048.
    #
    # Unpacks into a cache directory on first run, then runs beacon from there.
    # Everything it needs travels with it, including glibc and its loader, so
    # it does not care how old the host's C library is.
    #
    # Override the location with GLUE_HOME if $HOME is not where you want a few
    # hundred megabytes to land.
    set -eu

    ID=@ID@
    ROOT="''${GLUE_HOME:-''${XDG_CACHE_HOME:-$HOME/.cache}/glue}"
    DIR="$ROOT/$ID"

    # $0 is not a usable path when invoked through PATH.
    SELF="$0"
    case "$SELF" in
      */*) ;;
      *) SELF="$(command -v -- "$SELF")" ;;
    esac

    if [ ! -f "$DIR/.complete" ]; then
      for t in tar gzip; do
        command -v "$t" >/dev/null 2>&1 || {
          echo "glue: unpacking needs '$t', which is not on PATH." >&2
          echo "  Debian/Ubuntu:  apt-get install -y tar gzip" >&2
          echo "  RHEL/Rocky:     dnf install -y tar gzip" >&2
          echo "  Amazon Linux:   dnf install -y tar gzip" >&2
          echo "  Alpine:         apk add tar gzip" >&2
          exit 1
        }
      done

      # Unpack beside the target and rename, so an interrupted run cannot
      # leave a half-populated directory that looks ready to use.
      staging="$DIR.incomplete.$$"
      rm -rf "$staging"
      mkdir -p "$staging"

      start=$(awk '/^__GLUE_ARCHIVE_BELOW__$/ { print NR + 1; exit 0 }' "$SELF")
      tail -n +"$start" "$SELF" | tar xzf - -C "$staging"

      # Payload files come from the nix store, where they are read-only, and
      # GNU tar restores those modes -- on directories too. Without this the
      # tree cannot be marked complete, the interpreters cannot be rewritten,
      # and cleaning up a stale staging directory would fail as well.
      chmod -R u+w "$staging"

      # The half of relocation that cannot be done at build time. PT_INTERP is
      # read by the kernel, which does no $ORIGIN expansion, so it has to be an
      # absolute path -- and this directory was not known until just now.
      # RPATH is already $ORIGIN-relative and needs no fixing.
      #
      # The build left an over-long placeholder in each binary's .interp and
      # recorded its offset, so this is a byte overwrite rather than an ELF
      # rewrite: no patchelf on this machine, and nothing beyond a few bytes of
      # a 72 MiB binary is touched. The string is NUL-terminated, so writing the
      # path plus a NUL over a longer placeholder is all that is needed.
      #
      # Note the final directory is written, not the staging one: the tree is
      # renamed into place below.
      loader="$DIR/lib/$(cat "$staging/share/loader")"
      while read -r bin off cap; do
        if [ "''${#loader}" -ge "$cap" ]; then
          echo "glue: install path is too long for the reserved interpreter" >&2
          echo "  wanted: $loader (''${#loader} bytes, limit $cap)" >&2
          echo "  set GLUE_HOME to a shorter path and retry" >&2
          exit 1
        fi
        printf '%s\0' "$loader" \
          | dd of="$staging/bin/$bin" bs=1 seek="$off" conv=notrunc status=none
      done < "$staging/share/interp.offsets"

      touch "$staging/.complete"
      mkdir -p "$ROOT"
      rm -rf "$DIR"
      mv "$staging" "$DIR"
    fi

    # A bundled glibc must not be handed libraries from the host. Anything in
    # the caller's LD_* variables would be loaded into a process whose libc it
    # was never built against; a statically linked binary would have ignored
    # them for free, so scrub them explicitly.
    unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT

    # beacon locates jq and GNU `time` through PATH, so ours must come first:
    # jq is absent from base installs, and the host's `time` is usually a shell
    # builtin with no -v, in which case peak-memory and I/O figures are silently
    # not collected.
    PATH="$DIR/bin:$PATH"
    export PATH
    GLUE_ROOT="$DIR"
    export GLUE_ROOT

    # The bundled curl would otherwise look for CA certificates at a nix store
    # path that does not exist here.
    CURL_CA_BUNDLE="$DIR/share/ca-bundle.crt"
    export CURL_CA_BUNDLE
    SSL_CERT_FILE="$CURL_CA_BUNDLE"
    export SSL_CERT_FILE

    # Subcommands implemented as scripts rather than by beacon. They decide
    # *which* configurations to measure and how the data directory is prepared,
    # which is policy that changes more often than beacon does -- and being
    # shell, an operator can read them before trusting them.
    # No arguments means "do the whole job". An SPO should not have to know
    # that provisioning precedes fetching, nor that the report is a separate
    # artifact from the runs. Falling through to beacon here would have shown
    # them a developer's usage text instead.
    if [ $# -eq 0 ]; then
      exec "$DIR/scripts/glue-run-all.sh"
    fi

    case "''${1:-}" in
      run|run-all|--help|-h)
        # `run` is beacon's own subcommand name, but a bare `glue run` reaching
        # beacon would demand --rev and a chain name; this is what someone
        # typing it actually wants.
        case "$1" in --help|-h) ;; *) shift ;; esac
        exec "$DIR/scripts/glue-run-all.sh" "$@"
        ;;
      benchmark)
        shift
        exec "$DIR/scripts/glue-benchmark.sh" "$@"
        ;;
      provision)
        shift
        exec "$DIR/scripts/glue-provision.sh" "$@"
        ;;
      fetch)
        shift
        exec "$DIR/scripts/glue-fetch-chain.sh" "$@"
        ;;
      sysinfo)
        shift
        exec "$DIR/scripts/spo-sysinfo.sh" "$@"
        ;;
      report)
        shift
        exec "$DIR/scripts/glue-report.sh" "$@"
        ;;
    esac

    exec "$DIR/bin/beacon" "$@"
    __GLUE_ARCHIVE_BELOW__
  '';
in {
  mkSelfExtracting = {
    payload,
    name,
    version ? "0.1.0",
  }:
    pkgs.runCommand "${name}-${version}" {
      nativeBuildInputs = [pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.gnused];
      passthru = {inherit payload;};
    } ''
      # Deterministic: the same payload produces the same artifact, rather than
      # handing people a different download on every rebuild.
      tar \
        --sort=name \
        --mtime='@0' \
        --owner=0 --group=0 --numeric-owner \
        --format=gnu \
        -czf payload.tar.gz \
        -C ${payload} .

      id=$(sha256sum payload.tar.gz | cut -c1-16)
      sed "s/@ID@/$id/" ${header} > header.sh

      cat header.sh payload.tar.gz > $out
      chmod +x $out
    '';
}
