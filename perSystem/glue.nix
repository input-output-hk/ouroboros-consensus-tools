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

    supported = system == "x86_64-linux";

    # Precisely what IOG's Hydra builds and cache.iog.io serves: a ~45 MiB
    # substitution rather than a source build. `exesNoAsserts` is not
    # incidental -- assertions sit on the measured path and would skew every
    # timing we publish.
    dbAnalyser =
      consensus.hydraJobs.${system}.native.${compilerTag}.exesNoAsserts.db-analyser;

    beacon = hsPkgs.beacon.components.exes.beacon;

    # GNU time supplies the peak-RSS and block-I/O figures beacon reports. It
    # is bundled rather than assumed because `/usr/bin/time` is a separate
    # package on every distribution and frequently absent, and the shell's
    # `time` is a builtin with no -v/-o. Where it is missing beacon silently
    # collects no memory metrics at all, which is worse than failing.
    payload = pkgs.stdenvNoCC.mkDerivation {
      pname = "glue-payload";
      version = "0.1.0";
      dontUnpack = true;

      installPhase = ''
        mkdir -p $out/bin $out/share
        install -m755 ${beacon}/bin/beacon          $out/bin/beacon
        install -m755 ${dbAnalyser}/bin/db-analyser $out/bin/db-analyser
        install -m755 ${pkgs.time}/bin/time         $out/bin/time
      '';

      meta.mainProgram = "beacon";
    };

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
