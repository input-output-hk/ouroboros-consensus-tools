{inputs, ...}: {
  # The distributable of ouroboros-leios#1048: beacon plus the db-analyser it
  # drives, assembled so it runs on an SPO's machine with no nix and no
  # assumptions about the age of the host's C library.
  #
  # Phase 1 scope: linking and relocation only. beacon is unmodified here, so
  # it still resolves db-analyser through nix and cannot yet run offline --
  # that is the next phase. What this phase has to prove is that the artifact
  # starts on distributions older than the one it was built on.
  #
  # x86_64-linux only for now.
  perSystem = {
    hsPkgs,
    pkgs,
    lib,
    system,
    ...
  }: let
    consensus = inputs.ouroboros-consensus;

    # Consensus's own hydraJobs naming for the compiler.
    compilerTag = "haskell96";

    # Compared as a plain string rather than via pkgs.stdenv: `supported` gates
    # whether `packages` is defined at all, and using a module argument to
    # decide which options exist makes the module system recurse -- `pkgs`
    # itself comes from _module.args.
    supported = system == "x86_64-linux" || system == "aarch64-linux";

    # Whether consensus's flake declares this system. It lists x86_64-linux and
    # aarch64-darwin; aarch64-linux is commented out in its supportedSystems, so
    # there is no output to consume and nothing in the cache -- IOG has never
    # built it.
    upstreamAvailable = builtins.elem system (builtins.attrNames consensus.hydraJobs);

    # Where consensus builds this system, take precisely what its Hydra builds
    # and cache.iog.io serves: a ~45 MiB substitution rather than a source
    # build. `exesNoAsserts` is not incidental -- assertions sit on the measured
    # path and would skew every timing we publish.
    #
    # Where it does not -- aarch64-linux -- instantiate the same project from
    # source and reproduce that variant's patch. This must happen *on* aarch64:
    # haskell.nix evaluates Template Haskell splices through
    # iserv-proxy-interpreter, which has to load the target's object code, and
    # an x86_64 builder cannot load aarch64 objects. It dies inside libstdc++
    # with "Failed to lookup symbol: _Unwind_Resume" long before reaching our
    # code, so this is a native build on an ARM runner, not a cross-compile.
    consensusFromSource = pkgs.haskell-nix.cabalProject' {
      src = pkgs.applyPatches {
        name = "consensus-src-no-asserts";
        src = consensus;
        # Consensus disables assertions with a `noAsserts` flake variant that
        # blanks this file. Reproduced here because we are not going through
        # their flake.
        postPatch = "echo > cabal/asserts.cabal";
      };
      compiler-nix-name = "ghc967";
      inputMap = {"https://chap.intersectmbo.org/" = inputs.CHaP;};
    };

    dbAnalyser =
      if upstreamAvailable
      then consensus.hydraJobs.${system}.native.${compilerTag}.exesNoAsserts.db-analyser
      else consensusFromSource.hsPkgs.ouroboros-consensus.components.exes.db-analyser;

    beacon = hsPkgs.beacon.components.exes.beacon;

    # The cabal plan db-analyser was built from. beacon reads
    # <installPlanPath>/plan.json to record which ouroboros-consensus, ledger
    # and plutus versions produced a measurement. Without it mkManifest warns
    # and continues with an empty Manifest -- survivable, but the report then
    # cannot say what it measured.
    # Taken from whichever project produced the analyzer above, rather than
    # reaching into legacyPackages.${system} -- that attribute does not exist
    # where consensus does not declare the system, which is precisely the case
    # the from-source path handles.
    planNix =
      if upstreamAvailable
      then consensus.legacyPackages.${system}.hsPkgs.ouroboros-consensus.project.plan-nix
      else consensusFromSource.plan-nix;

    # nix reports lastModifiedDate as YYYYMMDDhhmmss; beacon parses
    # ciCommitDate as a UTCTime, so hand it ISO 8601.
    isoDate = d:
      lib.concatStrings [
        (builtins.substring 0 4 d)
        "-"
        (builtins.substring 4 2 d)
        "-"
        (builtins.substring 6 2 d)
        "T"
        (builtins.substring 8 2 d)
        ":"
        (builtins.substring 10 2 d)
        ":"
        (builtins.substring 12 2 d)
        "Z"
      ];

    analyzerSha = consensus.rev or "0000000000000000000000000000000000000000";
    analyzerDate = isoDate (consensus.lastModifiedDate or "19700101000000");

    # GNU time supplies the peak-RSS and block-I/O figures beacon reports. It
    # is bundled rather than assumed because `/usr/bin/time` is a separate
    # package on every distribution and frequently absent, and the shell's
    # `time` is a builtin with no -v/-o. Where it is missing beacon silently
    # collects no memory metrics at all, which is worse than failing.
    payload = pkgs.stdenvNoCC.mkDerivation {
      pname = "glue-payload";
      version = "0.1.0";
      dontUnpack = true;

      # nix rewrites `#!/bin/sh` to a store bash during fixupPhase, and that
      # path does not exist on an SPO's machine -- the scripts died with
      # "bad interpreter". /bin/sh is what they must keep: it is the one
      # interpreter every target is guaranteed to have.
      dontPatchShebangs = true;

      installPhase = ''
        mkdir -p $out/bin $out/share $out/analyzer/bin $out/scripts

        install -m755 ${beacon}/bin/beacon          $out/bin/beacon
        install -m755 ${dbAnalyser}/bin/db-analyser $out/bin/db-analyser
        install -m755 ${pkgs.time}/bin/time         $out/bin/time

        # beacon reshapes db-analyser's JSON-lines output, and merges run
        # metadata, by shelling out to jq (four call sites on the run path).
        # Bundled rather than assumed: jq is not in base on Debian, Ubuntu or
        # RHEL.
        install -m755 ${pkgs.jq}/bin/jq             $out/bin/jq

        # Chain acquisition. Bundled rather than required of the host: curl is
        # absent from Debian netinst and minimal container images, and unzip is
        # a separate package on every distribution. Bundling both is ~2 MiB and
        # keeps chains-v1 usable as published.
        install -m755 ${pkgs.curl}/bin/curl         $out/bin/curl
        install -m755 ${pkgs.unzip}/bin/unzip       $out/bin/unzip

        # `zip` for assembling the report. The host is already required to have
        # tar and gzip, so a .tar.gz would have cost nothing -- but a zip is what
        # the person on the other end can open without thinking about it, and at
        # ~200 KiB the bundled copy also means the archive does not depend on
        # whatever tar the host happens to ship.
        install -m755 ${pkgs.zip}/bin/zip           $out/bin/zip

        # nixpkgs curl looks for CA certificates at a store path that will not
        # exist on the target, so HTTPS would fail. The risk this pins is
        # bounded: every fragment is checked against a sha256 baked into the
        # table, so TLS is defence in depth rather than the integrity guarantee.
        cp ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt $out/share/ca-bundle.crt

        # shellNixBuildVersion skips nix entirely when
        # <data-dir>/bin/<sha9>-<compiler>/bin/db-analyser already exists, and
        # then readlinks that directory -- so what gets staged into the data
        # directory has to be a symlink to a directory shaped like this. A
        # relative symlink back to bin/ avoids carrying a second 72 MiB copy.
        ln -s ../../bin/db-analyser $out/analyzer/bin/db-analyser

        cp ${planNix}/plan.json $out/share/plan.json

        # Sourceable rather than JSON: the provisioning script needs these and
        # nothing should have to parse JSON in shell.
        cat > $out/share/pin.env <<EOF
        ANALYZER_SHA=${analyzerSha}
        ANALYZER_DATE=${analyzerDate}
        ANALYZER_COMPILER=${compilerTag}
        EOF

        cp ${checkedScripts}/glue-provision.sh  $out/scripts/glue-provision.sh
        cp ${checkedScripts}/glue-benchmark.sh  $out/scripts/glue-benchmark.sh
        cp ${checkedScripts}/glue-fetch-chain.sh  $out/scripts/glue-fetch-chain.sh
        cp ${checkedScripts}/spo-sysinfo.sh  $out/scripts/spo-sysinfo.sh
        cp ${checkedScripts}/glue-report.sh  $out/scripts/glue-report.sh
        cp ${checkedScripts}/glue-run-all.sh  $out/scripts/glue-run-all.sh
        chmod +x $out/scripts/*.sh

        cp ${../data/chains.tsv}     $out/share/chains.tsv
        cp ${../data/chains.baseurl} $out/share/chains.baseurl
      '';

      meta.mainProgram = "beacon";
    };

    # The scripts are shipped verbatim, so a syntax error in one of them would
    # pass `nix build` and fail on an SPO's machine. Checking them here rather
    # than only in CI means the payload cannot be built with a broken script in
    # it -- and `-s sh` matters: these run under /bin/sh, which on Debian and
    # Ubuntu is dash, not bash.
    checkedScripts =
      pkgs.runCommand "glue-scripts-checked" {
        nativeBuildInputs = [pkgs.shellcheck];
        # runCommand runs fixupPhase, which would rewrite #!/bin/sh to a store
        # bash -- the exact breakage this payload was already fixed for once.
        # The scripts must reach the target with the interpreter every Linux
        # has.
        dontPatchShebangs = true;
      } ''
        mkdir -p $out
        for f in ${../scripts}/*.sh; do
          echo "shellcheck $(basename "$f")"
          shellcheck -s sh "$f"
          install -m755 "$f" "$out/$(basename "$f")"
        done
      '';

    inherit (import ../nix/bundle.nix {inherit pkgs lib;}) mkRelocatable;
    inherit (import ../nix/selfextract.nix {inherit pkgs lib;}) mkSelfExtracting;

    relocatable = mkRelocatable payload;
  in
    lib.optionalAttrs supported {
      packages = {
        glue-payload = payload;
        glue-relocatable = relocatable;
        db-analyser = dbAnalyser;

        # The artifact people download.
        glue = mkSelfExtracting {
          payload = relocatable;
          name = "glue";
        };
      };
    };
}
