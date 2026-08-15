# Wrap a payload tree into one executable file.
#
# "Download and run" is the premise of ouroboros-leios#1048, and a directory of
# binaries is not that. This produces a single file: a small POSIX shell header
# with a gzipped tar of the payload appended. Running it extracts to a cache
# directory once, then execs beacon from there; later runs skip to the exec.
#
# The one host dependency is tar/gzip. That is a deliberate line: they are
# present on every Linux and macOS system in practice, unlike jq or a GNU
# `time`, which is why those are bundled and these are not. Bundling a tar to
# unpack the archive containing the tar is not a solvable problem.
#
# Not nix-bundle or an AppImage: both are Linux-only, and nix-bundle
# additionally requires unprivileged user namespaces, which several hardened
# distributions disable by default. A kernel feature that is sometimes off is
# exactly the sort of invisible dependency this is meant to avoid.
{
  pkgs,
  lib,
}: let
  # @ID@ is replaced at build time with a hash of the archive. Kept as a
  # separate file rather than a heredoc inside the builder: nesting shell
  # quoting inside nix quoting inside a heredoc is how these scripts acquire
  # bugs that only appear on someone else's machine.
  header = pkgs.writeText "glue-header.sh" ''
    #!/bin/sh
    # Self-extracting distributable of ouroboros-leios#1048.
    #
    # Unpacks into a cache directory on first run, then runs beacon from there.
    # Everything it needs is inside; the only thing downloaded later is the
    # chain fragment, and only when you ask it to benchmark.
    #
    # Override the location with GLUE_HOME if $HOME is not where you want
    # a few hundred megabytes to land.
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

      # Unpack beside the target and rename, so an interrupted extraction
      # cannot leave a half-populated directory that looks ready to run.
      staging="$DIR.incomplete.$$"
      rm -rf "$staging"
      mkdir -p "$staging"

      start=$(awk '/^__GLUE_ARCHIVE_BELOW__$/ { print NR + 1; exit 0 }' "$SELF")
      tail -n +"$start" "$SELF" | tar xzf - -C "$staging"

      touch "$staging/.complete"
      mkdir -p "$ROOT"
      rm -rf "$DIR"
      mv "$staging" "$DIR"
    fi

    exec "$DIR/bin/beacon" "$@"
    __GLUE_ARCHIVE_BELOW__
  '';
in {
  # `payload` must contain bin/beacon; `name` becomes the artifact filename.
  mkSelfExtracting = {
    payload,
    name,
    version ? "0.1.0",
  }:
    pkgs.runCommand "${name}-${version}" {
      nativeBuildInputs = [pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.gnused];
      passthru = {inherit payload;};
    } ''
      # Deterministic archive: the same payload produces the same artifact, so
      # a rebuild does not hand people a different download for no reason.
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
