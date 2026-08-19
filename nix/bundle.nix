# Make a payload of nix-store-linked ELF binaries runnable on a machine that
# has no /nix/store and whose glibc is older than ours.
#
# The binaries reference absolute store paths for every shared library, and
# require symbol versions up to GLIBC_2.38 -- newer than RHEL 8 (2.28),
# RHEL 9 / Amazon Linux 2023 (2.34) or Ubuntu 22.04 (2.35). So relying on the
# host's glibc is not an option; glibc and its loader travel with us.
#
# Two halves, split by when they can be done:
#
#   here, at build time   copy the dependency closure into lib/, and set
#                         RPATH to $ORIGIN/../lib so libraries are found
#                         relative to the binary wherever it ends up
#
#   at extraction time    set PT_INTERP to the unpacked loader. This cannot
#                         happen now: PT_INTERP is read by the kernel, which
#                         performs no $ORIGIN expansion, so it must be an
#                         absolute path -- and the install directory is not
#                         known until the artifact is unpacked. See
#                         nix/selfextract.nix.
{
  pkgs,
  lib,
}: {
  mkRelocatable = payload:
    pkgs.runCommand "glue-relocatable-${payload.version or "0"}" {
      nativeBuildInputs = [
        pkgs.patchelf
        pkgs.glibc.bin # ldd
      ];
      passthru = {inherit payload;};
    } ''
      cp -r ${payload} $out
      chmod -R u+w $out
      mkdir -p $out/lib $out/libexec $out/share

      is_elf() { patchelf --print-interpreter "$1" >/dev/null 2>&1; }

      # The dependency closure, resolved by the loader itself rather than from
      # a hand-maintained list. libnuma turned up in the real closure having
      # been absent from every list we wrote by hand; deriving it means the
      # next upstream addition is picked up silently instead of failing on an
      # SPO's machine.
      : > /tmp/libs
      loader=""
      for b in $out/bin/*; do
        is_elf "$b" || continue
        loader="$(patchelf --print-interpreter "$b")"
        ldd "$b" | while read -r name arrow path rest; do
          case "$name" in
            linux-vdso.so.1|linux-gate.so.1) continue ;;
          esac
          if [ "$arrow" = "=>" ] && [ -e "$path" ]; then
            echo "$path" >> /tmp/libs
          elif [ -e "$name" ]; then
            # The loader line has no "=>" -- it is printed as a bare path.
            echo "$name" >> /tmp/libs
          fi
        done
      done

      sort -u /tmp/libs > /tmp/libs.uniq
      echo "bundling $(wc -l < /tmp/libs.uniq) shared objects:"
      while read -r l; do
        install -m755 "$l" "$out/lib/$(basename "$l")"
        echo "  $(basename "$l")"
      done < /tmp/libs.uniq

      # The loader is invoked by the kernel, not searched for, so it needs no
      # RPATH of its own -- and rewriting it is a good way to break it.
      loader_name="$(basename "$loader")"
      install -m755 "$loader" "$out/lib/$loader_name"
      echo "$loader_name" > $out/share/loader

      # Libraries find their siblings; executables look one level up.
      for l in $out/lib/*; do
        [ "$(basename "$l")" = "$loader_name" ] && continue
        patchelf --set-rpath '$ORIGIN' "$l" 2>/dev/null || true
      done
      for b in $out/bin/*; do
        is_elf "$b" || continue
        patchelf --set-rpath '$ORIGIN/../lib' "$b"
      done

      # Statically linked on purpose: this runs at extraction time, before any
      # interpreter has been pointed anywhere, so it cannot itself depend on a
      # loader we have not set up yet.
      install -m755 ${pkgs.pkgsStatic.patchelf}/bin/patchelf $out/libexec/patchelf

      echo "--- resulting linkage of bin/beacon ---"
      patchelf --print-rpath $out/bin/beacon
      patchelf --print-interpreter $out/bin/beacon
    '';
}
