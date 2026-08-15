# Turn a payload of nix-store-linked binaries into a self-contained tree that
# runs on a machine with no /nix/store.
#
# Why this is needed at all: the payload's binaries record absolute store
# paths for every shared library they need
#
#   beacon      -> /nix/store/...-cairo-1.18.4/lib/libcairo.2.dylib, ...
#   db-analyser -> /nix/store/...-blst-8c7db7f/lib/libblst.dylib, ...
#
# so copying the payload elsewhere produces binaries that cannot start. We
# walk the dependency graph, copy every store-resident library into lib/, and
# rewrite the references to be relative to the binary's own location.
#
# Deliberately not `wrapProgram`/`makeWrapper`: those inject absolute store
# paths, which is the very thing that breaks under relocation.
{
  pkgs,
  lib,
}: let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # Libraries the target OS always provides. Everything else travels with us.
  systemPrefixes =
    if isDarwin
    then ''["/usr/lib/", "/System/"]''
    else ''["/lib/", "/lib64/", "/usr/lib/"]'';

  relocateDarwin = ''
    import os, shutil, subprocess, sys

    OUT   = sys.argv[1]
    BIN   = os.path.join(OUT, "bin")
    LIBS  = os.path.join(OUT, "lib")
    SYSTEM_PREFIXES = ${systemPrefixes}

    def deps(path):
        out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
        result = []
        for line in out.splitlines()[1:]:
            line = line.strip()
            if not line:
                continue
            dep = line.split()[0]
            if any(dep.startswith(p) for p in SYSTEM_PREFIXES):
                continue
            if dep.startswith("@"):
                continue
            result.append(dep)
        return result

    # 1. Collect the transitive closure of non-system libraries.
    os.makedirs(LIBS, exist_ok=True)
    binaries = [os.path.join(BIN, f) for f in sorted(os.listdir(BIN))]
    collected = {}          # source store path -> basename in lib/
    work = list(binaries)
    while work:
        nxt = []
        for f in work:
            for d in deps(f):
                if d in collected:
                    continue
                base = os.path.basename(d)
                # Distinct store paths can share a basename; keep them apart.
                if base in collected.values():
                    tag = os.path.basename(os.path.dirname(os.path.dirname(d)))
                    base = tag + "-" + base
                collected[d] = base
                nxt.append(d)
        work = nxt

    for src, base in collected.items():
        dst = os.path.join(LIBS, base)
        shutil.copy(src, dst)
        os.chmod(dst, 0o755)

    # 2. Rewrite every reference to point at the copied library.
    #    Executables reach lib/ via @executable_path/../lib; libraries sit
    #    beside each other, so they use @loader_path.
    def rewrite(path, prefix):
        args = []
        for src, base in collected.items():
            args += ["-change", src, prefix + base]
        if args:
            subprocess.run(["install_name_tool", *args, path], check=True,
                           stderr=subprocess.DEVNULL)

    for f in binaries:
        rewrite(f, "@executable_path/../lib/")

    for base in collected.values():
        p = os.path.join(LIBS, base)
        rewrite(p, "@loader_path/")
        # A library's own recorded id is still its store path; anything that
        # links against it would resolve that instead of our copy.
        subprocess.run(["install_name_tool", "-id", "@loader_path/" + base, p],
                       check=True, stderr=subprocess.DEVNULL)

    # 3. Every edit invalidates the code signature, and arm64 macOS refuses to
    #    run an incorrectly-signed binary. Re-sign ad-hoc.
    for p in binaries + [os.path.join(LIBS, b) for b in collected.values()]:
        subprocess.run(["codesign", "--force", "--sign", "-", p],
                       check=True, stderr=subprocess.DEVNULL)

    print("relocated %d binaries, %d libraries" % (len(binaries), len(collected)))
  '';
in {
  # Produces a directory tree that can be copied anywhere and run.
  mkRelocatable = payload:
    pkgs.runCommand "glue-relocatable-${payload.version or "0"}" {
      nativeBuildInputs =
        [pkgs.python3]
        # sigtool provides a `codesign` that works inside the build sandbox;
        # /usr/bin/codesign is not available there.
        ++ lib.optionals isDarwin [pkgs.darwin.cctools pkgs.darwin.sigtool]
        ++ lib.optionals (!isDarwin) [pkgs.patchelf];
      passthru = {inherit payload;};
    } (
      if isDarwin
      then ''
        cp -r ${payload} $out
        chmod -R u+w $out
        python3 ${pkgs.writeText "relocate-darwin.py" relocateDarwin} $out
      ''
      else
        throw ''
          Linux relocation is not implemented yet.

          It is not a port of the Darwin path: on ELF the interpreter (PT_INTERP)
          is an absolute path that does NOT expand $ORIGIN, so the loader cannot
          be found relative to the binary the way libraries can. That forces a
          strategy choice -- see the notes in this file's commit message.
        ''
    );
}
