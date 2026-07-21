{...}: {
  perSystem = {
    pkgs,
    lib,
    system,
    ...
  }: let
    checkFormatting = tool: script:
      pkgs.runCommand
      "check-${lib.getName tool}"
      {
        buildInputs = [pkgs.fd tool];
        src = ../.;
      } ''
        unpackPhase
        cd $sourceRoot

        bash ${script}

        EXIT_CODE=0
        diff -ru $src . || EXIT_CODE=$?

        if [[ $EXIT_CODE != 0 ]]
        then
          echo "*** ${tool.name} found changes that need addressed first"
          exit $EXIT_CODE
        else
          echo $EXIT_CODE > $out
        fi
      '';

    formattingTools = {
      stylish = checkFormatting pkgs.stylish-haskell ../scripts/ci/run-stylish.sh;
      cabal-fmt = checkFormatting pkgs.haskellPackages.cabal-fmt ../scripts/ci/run-cabal-fmt.sh;
      alejandra = checkFormatting pkgs.alejandra ../scripts/ci/run-alejandra.sh;
    };
  in {
    # a single "formatting" check in the checks matrix, only run for one
    # system; it aggregates the individual per-tool formatting checks.
    checks = lib.optionalAttrs (system == "x86_64-linux") {
      formatting = pkgs.releaseTools.aggregate {
        name = "formatting";
        constituents = builtins.attrValues formattingTools;
      };
    };
  };
}
