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

    # Precisely what IOG's Hydra builds and cache.iog.io serves. `exesNoAsserts`
    # is not incidental: assertions sit on the measured path and would skew
    # every timing we publish.
    dbAnalyser =
      consensus.hydraJobs.${system}.native.${compilerTag}.exesNoAsserts.db-analyser;

    # Plotting off: Chart-cairo would otherwise drag cairo, glib, fontconfig,
    # freetype, pixman and X11 into a distributable that never draws a plot,
    # and stands in the way of linking it statically for Linux.
    beacon =
      (hsPkgs.beacon.project.appendModule {
        # Set through cabalProjectLocal, not only as a module flag: a module
        # flag changes how the component is configured but not the solved
        # cabal plan, so Chart-cairo would still be built and would drag in
        # cairo and glib.
        cabalProjectLocal = ''
          package beacon
            flags: -plots
        '';
        modules = [{packages.beacon.flags.plots = false;}];
      })
      .hsPkgs.beacon.components.exes.beacon;

    # The cabal build plan db-analyser was built from. beacon reads
    # `<installPlanPath>/plan.json` to record which ouroboros-consensus /
    # ledger / plutus versions produced a measurement (mkManifest). Without
    # it mkManifest degrades to an empty Manifest with a warning, so bake it
    # in: 1.9 MiB is cheap for knowing what a report actually measured.
    #
    # `legacyPackages` rather than a hydraJobs path on purpose: consensus's CI
    # skips the `build` jobs off Linux, but legacyPackages exposes the same
    # project -- and thus the same shared, project-wide plan -- everywhere.
    planNix =
      consensus.legacyPackages.${system}.hsPkgs.ouroboros-consensus.project.plan-nix;

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
    # from db-analyser. This file failing loudly is preferable to discovering
    # that mid-benchmark.
    capabilities = pkgs.runCommand "db-analyser-capabilities" {} ''
      help="$(${dbAnalyser}/bin/db-analyser --help 2>&1 || true)"
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
    # today resolves db-analyser via `nix build github:IntersectMBO/...`
    # (shellNixBuildVersion) and its commit metadata via the GitHub API
    # (BeaconLoadCommit). Both are build-time facts; a distributed binary has
    # neither nix nor a network, so they are frozen here instead.
    provenance = {
      payloadVersion = 1;
      inherit system;
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
      };
    };

    provenanceFile = pkgs.writeText "provenance.json" (builtins.toJSON provenance);

    payload = pkgs.stdenvNoCC.mkDerivation {
      pname = "glue-payload";
      version = "0.1.0";
      dontUnpack = true;

      installPhase = ''
        mkdir -p $out/bin $out/share

        install -m755 ${beacon}/bin/beacon           $out/bin/beacon
        install -m755 ${dbAnalyser}/bin/db-analyser  $out/bin/db-analyser

        # `jq` reshapes db-analyser's JSON-lines output; GNU `time` supplies the
        # peak-RSS and block-I/O figures. Both are tiny (1.0 and 0.1 MiB closures)
        # next to the payload's ~476 MiB, and bundling GNU time in particular
        # avoids relying on the host's -- macOS and busybox ship a `time` with
        # no -v/-o, which silently costs the run its memory metrics.
        install -m755 ${pkgs.jq}/bin/jq              $out/bin/jq
        install -m755 ${pkgs.time}/bin/time          $out/bin/time

        cp ${provenanceFile}                 $out/share/provenance.json
        cp ${capabilities}/capabilities.json $out/share/capabilities.json
        cp ${planNix}/plan.json              $out/share/plan.json
      '';

      passthru = {inherit provenance dbAnalyser capabilities;};
      meta.mainProgram = "beacon";
    };
    inherit (import ../nix/relocate.nix {inherit pkgs lib;}) mkRelocatable;
  in
    lib.optionalAttrs available {
      packages.glue-payload = payload;
      packages.db-analyser = dbAnalyser;

      # The payload with every /nix/store library reference rewritten to be
      # relative to the binaries themselves, so the tree can be copied to a
      # machine that has no store. This is what gets archived for SPOs.
      packages.glue-relocatable = mkRelocatable payload;
    };
}
