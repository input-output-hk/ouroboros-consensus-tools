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
      command -v tar >/dev/null 2>&1 || {
        echo "glue: unpacking needs 'tar', which is not on PATH" >&2
        exit 1
      }

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
      loader="$staging/lib/$(cat "$staging/share/loader")"
      for b in "$staging"/bin/*; do
        if "$staging/libexec/patchelf" --print-interpreter "$b" >/dev/null 2>&1; then
          "$staging/libexec/patchelf" --set-interpreter "$loader" "$b"
        fi
      done

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
