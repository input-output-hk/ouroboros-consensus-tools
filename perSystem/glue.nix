{inputs, ...}: {
  # The distributable "glue" payload of ouroboros-leios#1048: beacon plus the
  # db-analyser it drives plus everything it would otherwise have to discover
  # over the network, assembled into one self-contained tree.
  #
  # `beacon` *is* glue here. It already drives db-analyser, stores runs and
  # summarizes them; what a distributed build additionally needs is the chain
  # data and the ability to run with no nix and no network. So this file adds
  # no orchestration -- it only assembles, and bakes in the facts beacon would
  # otherwise curl or probe for.
  #
  # Two flavours are produced:
  #
  #   glue-payload         dynamically linked; needs nix/relocate.nix to leave
  #                        the build machine (implemented for darwin only)
  #   glue-payload-static  linked against musl with no shared libraries at all,
  #                        so relocation is a copy. This is the Linux answer:
  #                        on ELF, PT_INTERP is absolute and does not expand
  #                        $ORIGIN, so a dynamically linked tree cannot find
  #                        its own loader after being moved.
  perSystem = {
    hsPkgs,
    pkgs,
    lib,
    system,
    ...
  }: let
    consensus = inputs.ouroboros-consensus;

    # Consensus's own hydraJobs naming for the compiler; beacon uses the same
    # tag when resolving a db-analyser build.
    compilerTag = "haskell96";

    # Consensus's flake declares only x86_64-linux and aarch64-darwin
    # (aarch64-linux is commented out in its supportedSystems), so there is
    # nothing to consume -- and nothing in the cache, since IOG has never
    # built it -- on aarch64-linux. That target needs a from-source build,
    # which is the outstanding piece of ouroboros-leios#1048.
    consensusSystems = builtins.attrNames consensus.hydraJobs;
    available = builtins.elem system consensusSystems;

    isLinux = pkgs.stdenv.hostPlatform.isLinux;

    # Static payloads are built for both Linux targets, but only ever
    # same-architecture: x86_64 -> x86_64-musl, aarch64 -> aarch64-musl.
    #
    # Cross-*architecture* is not an option, and not for want of a flag.
    # haskell.nix evaluates Template Haskell splices through
    # iserv-proxy-interpreter, which has to load the target's object code; an
    # x86_64 builder cannot load aarch64 objects, and the build dies in
    # libstdc++ with "Failed to lookup symbol: _Unwind_Resume" long before it
    # reaches our code. musl64 on x86_64 works precisely because it is the
    # same architecture.
    staticAvailable = isLinux;

    muslCross =
      if system == "aarch64-linux"
      then "aarch64-multiplatform-musl"
      else "musl64";

    # Precisely what IOG's Hydra builds and cache.iog.io serves. `exesNoAsserts`
    # is not incidental: assertions sit on the measured path and would skew
    # every timing we publish.
    dbAnalyser =
      consensus.hydraJobs.${system}.native.${compilerTag}.exesNoAsserts.db-analyser;

    # Plotting off: Chart-cairo would otherwise drag cairo, glib, fontconfig,
    # freetype, pixman and X11 into a distributable that never draws a plot,
    # and stands in the way of linking it statically for Linux.
    beaconProject = hsPkgs.beacon.project.appendModule {
      modules = [{packages.beacon.flags.plots = false;}];
    };

    beacon = beaconProject.hsPkgs.beacon.components.exes.beacon;

    # -- static (musl) flavour -------------------------------------------
    #
    # Nothing here is cached: consensus's CI cross-compiles only to ucrt64
    # (Windows), so cache.iog.io has no musl db-analyser and this is a
    # from-source build of consensus and its whole dependency tree. That cost
    # is the price of a Linux artifact that can actually be copied to an SPO's
    # machine, and it is paid once per pin rather than per user.
    #
    # haskell.nix's musl cross disables shared libraries, so executables come
    # out static without further -optl flags. CI asserts that rather than
    # trusting it.
    # Where consensus's flake declares this system we use its own project, so
    # native builds keep hitting cache.iog.io. Where it does not -- aarch64-linux
    # -- we instantiate the same project from its source. That is only viable
    # because the static payload is a from-source build regardless.
    consensusProject =
      if available
      then consensus.legacyPackages.${system}.hsPkgs.ouroboros-consensus.project
      else
        pkgs.haskell-nix.cabalProject' {
          src = pkgs.applyPatches {
            name = "consensus-src-no-asserts";
            src = consensus;
            # Consensus disables assertions with a `noAsserts` flake variant
            # that blanks this file; reproduced here since we are not going
            # through their flake. Assertions sit on the measured path.
            postPatch = "echo > cabal/asserts.cabal";
          };
          compiler-nix-name = "ghc967";
          inputMap = {"https://chap.intersectmbo.org/" = inputs.CHaP;};
        };

    # The noAsserts variant only exists on the flake-provided project; the
    # from-source one already has assertions patched out.
    consensusNoAsserts =
      if available
      then consensusProject.projectVariants.noAsserts
      else consensusProject;

    # The LSM backend links liburing (io_uring). The musl package set puts only
    # a shared build in the default link path, so a fully static link fails:
    #
    #   ld: cannot find -luring: No such file or directory
    #   ld: have you installed the static version of the uring library ?
    #
    # Point the linker at a static build of it. Everything else db-analyser
    # needs -- blst, secp256k1, libsodium -- already links statically.
    staticLinkModule = {
      pkgs,
      lib,
      ...
    }:
      lib.mkIf pkgs.stdenv.hostPlatform.isMusl {
        packages.ouroboros-consensus.components.exes.db-analyser.configureFlags = [
          "--ghc-option=-optl=-L${pkgs.pkgsStatic.liburing}/lib"
        ];
      };

    # db-analyser lives in the `ouroboros-consensus` package, not in an
    # `ouroboros-consensus-cardano` one -- that package does not exist at this
    # pin, which is also why the run manifest lists only ouroboros-consensus.
    dbAnalyserStatic =
      (consensusNoAsserts.appendModule {
        modules = [staticLinkModule];
      })
      .projectCross.${
        muslCross
      }
      .hsPkgs.ouroboros-consensus.components.exes.db-analyser;

    beaconStatic =
      beaconProject.projectCross.${muslCross}.hsPkgs.beacon.components.exes.beacon;

    # The cabal build plan db-analyser was built from. beacon reads
    # `<installPlanPath>/plan.json` to record which ouroboros-consensus /
    # ledger / plutus versions produced a measurement (mkManifest). Without
    # it mkManifest degrades to an empty Manifest with a warning, so bake it
    # in: 1.9 MiB is cheap for knowing what a report actually measured.
    #
    # `legacyPackages` rather than a hydraJobs path on purpose: consensus's CI
    # skips the `build` jobs off Linux, but legacyPackages exposes the same
    # project -- and thus the same shared, project-wide plan -- everywhere.
    #
    # The native plan is used for both flavours: cross-compiling to musl does
    # not change the versions of the packages named in the manifest, which is
    # all beacon reads out of it.
    # Taken from whichever project was selected above, rather than reaching
    # into legacyPackages again: that attribute does not exist on
    # aarch64-linux, which is the whole reason the from-source project exists.
    planNix = consensusProject.plan-nix;

    # nix gives us lastModifiedDate as "YYYYMMDDhhmmss"; beacon's CommitInfo
    # parses ciCommitDate as a UTCTime, so hand it ISO 8601.
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

    # Which optional db-analyser flags this exact build understands.
    #
    # beacon currently discovers this at runtime by grepping `--help`
    # (detectEnvironmentCapabilities in Run.hs). Since the payload pins one
    # db-analyser, the build already knows -- so record it once here rather
    # than re-probing on every SPO's machine.
    #
    # Note as of the current pin: --lmdb and --only-immutable-db are *gone*
    # from db-analyser. This failing loudly is preferable to discovering that
    # mid-benchmark.
    mkCapabilities = analyzer:
      pkgs.runCommand "db-analyser-capabilities" {} ''
        help="$(${analyzer}/bin/db-analyser --help 2>&1 || true)"
        has() {
          if echo "$help" | grep -qw -- "$1"; then echo true; else echo false; fi
        }

        mkdir -p $out
        cat > $out/capabilities.json <<EOF
        {
          "onlyImmutableDb":    $(has --only-immutable-db),
          "lsmNoCache":         $(has --lsm-no-cache),
          "benchmarkLedgerOps": $(has --benchmark-ledger-ops),
          "reapply":            $(has --reapply),
          "backends": {
            "inMem": $(has --in-mem),
            "lsm":   $(has --lsm),
            "lmdb":  $(has --lmdb)
          }
        }
        EOF
      '';

    # Everything beacon would otherwise reach the network for. `beacon run`
    # resolves db-analyser via `nix build github:IntersectMBO/...`
    # (shellNixBuildVersion) and its commit metadata via the GitHub API
    # (BeaconLoadCommit). Both are build-time facts; a distributed binary has
    # neither nix nor a network, so they are frozen here instead.
    mkProvenance = static: {
      payloadVersion = 1;
      inherit system static;
      analyzer = {
        name = "db-analyser";
        # Named to match beacon's CommitInfo fields, so the baked value drops
        # straight into the run metadata that `beacon run` would otherwise
        # have fetched from the GitHub API.
        ciCommitSHA1 = consensus.rev or "unknown";
        ciCommitDate = isoDate (consensus.lastModifiedDate or "19700101000000");
        compiler = compilerTag;
        assertionsDisabled = true;
      };
      summarizer = {
        name = "beacon";
        version = hsPkgs.beacon.identifier.version;
        commitSHA1 = inputs.self.rev or inputs.self.dirtyRev or "dirty";
      };

      # Helper executables shipped in bin/, as name -> filename. beacon
      # resolves these relative to its own executable rather than trusting
      # $PATH, so a host without them (or with a non-GNU `time`) still gets
      # the behaviour the benchmark expects.
      #
      # They are recorded here rather than injected via wrapProgram
      # deliberately: a wrapper bakes absolute /nix/store paths, and the
      # payload is meant to be relocated to machines that have no store.
      tools = {
        jq = "jq";
        time = "time";
        # Chain acquisition. curl for a resumable, redirect-following download
        # of an ~800 MiB fragment; unzip to unpack it. Bundled rather than
        # assumed for the same reason as the others -- and because a static
        # musl beacon linking a TLS stack of its own would be a much larger
        # commitment than shipping a curl that already works.
        curl = "curl";
        unzip = "unzip";
      };
    };

    mkPayload = {
      pname,
      beaconExe,
      analyzerExe,
      jq,
      time,
      curl,
      unzip,
      static,
      # Probe a different binary for supported flags. Needed when the payload's
      # own db-analyser is for another architecture and cannot be executed here.
      capabilitiesFrom ? null,
    }: let
      provenanceFile =
        pkgs.writeText "provenance.json" (builtins.toJSON (mkProvenance static));
      capabilities = mkCapabilities (
        if capabilitiesFrom == null
        then analyzerExe
        else capabilitiesFrom
      );
    in
      pkgs.stdenvNoCC.mkDerivation {
        inherit pname;
        version = "0.1.0";
        dontUnpack = true;

        installPhase = ''
          mkdir -p $out/bin $out/share

          install -m755 ${beaconExe}/bin/beacon          $out/bin/beacon
          install -m755 ${analyzerExe}/bin/db-analyser   $out/bin/db-analyser

          # `jq` reshapes db-analyser's JSON-lines output; GNU `time` supplies
          # the peak-RSS and block-I/O figures. Bundling GNU time in particular
          # avoids relying on the host's -- macOS and busybox ship a `time`
          # with no -v/-o, which silently costs the run its memory metrics.
          install -m755 ${jq}/bin/jq                     $out/bin/jq
          install -m755 ${time}/bin/time                 $out/bin/time
          install -m755 ${curl}/bin/curl                 $out/bin/curl
          install -m755 ${unzip}/bin/unzip               $out/bin/unzip

          cp ${provenanceFile}                 $out/share/provenance.json
          cp ${capabilities}/capabilities.json $out/share/capabilities.json
          cp ${../data/chain-manifest.json}    $out/share/chain-manifest.json
          cp ${planNix}/plan.json              $out/share/plan.json
        '';

        passthru = {
          inherit capabilities static;
          provenance = mkProvenance static;
        };
        meta.mainProgram = "beacon";
      };

    payload = mkPayload {
      pname = "glue-payload";
      beaconExe = beacon;
      analyzerExe = dbAnalyser;
      inherit (pkgs) jq time curl unzip;
      static = false;
    };

    payloadStatic = mkPayload {
      pname = "glue-payload-static";
      beaconExe = beaconStatic;
      analyzerExe = dbAnalyserStatic;
      inherit (pkgs.pkgsStatic) jq time curl unzip;
      static = true;
    };

    inherit (import ../nix/relocate.nix {inherit pkgs lib;}) mkRelocatable;
    inherit (import ../nix/selfextract.nix {inherit pkgs lib;}) mkSelfExtracting;
  in {
    # NB: one `packages` attrset, merged before assignment. Two attrsets
    # combined with `//` would have the static side replace the whole
    # `packages` key rather than adding to it.
    packages =
      lib.optionalAttrs available {
        glue-payload = payload;
        db-analyser = dbAnalyser;

        # The payload with every /nix/store library reference rewritten to be
        # relative to the binaries themselves, so the tree can be copied to a
        # machine that has no store. Darwin only; Linux uses the static
        # flavour instead, which needs no rewriting.
        glue-relocatable = mkRelocatable payload;

        # The artifact people actually download: one executable file.
        # On darwin that wraps the relocated tree; on Linux the static one,
        # which needs no relocation at all (see below).
        glue = mkSelfExtracting {
          payload = mkRelocatable payload;
          name = "glue";
        };
      }
      // lib.optionalAttrs staticAvailable {
        glue-payload-static = payloadStatic;

        # Linux's single-file artifact. Overrides the darwin-oriented `glue`
        # above, because a statically linked payload is already relocatable.
        glue = mkSelfExtracting {
          payload = payloadStatic;
          name = "glue";
        };

        db-analyser-static = dbAnalyserStatic;
        beacon-static = beaconStatic;
      };
  };
}
