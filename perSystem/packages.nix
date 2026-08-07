{
  perSystem = {
    hsPkgs,
    pkgs,
    ...
  }: let
    bc = hsPkgs.beacon;
    beacon = bc.components.exes.beacon;
  in {
    packages.beacon = beacon;

    # Imports zipped chain fragments + a chain-register.json fragment
    # received from someone else, then runs the on-disk LSM/no-page-cache
    # beacon benchmark (no heap limit) against each and prints its summary.
    # `beacon`, `jq`, and `unzip` are provided on PATH, so this can be run
    # via `nix run` without a local checkout.
    packages.beacon-import-and-benchmark = pkgs.stdenvNoCC.mkDerivation {
      pname = "beacon-import-and-benchmark";
      version = "0.1.0";
      src = ../scripts/run-received-chains-lsmnc-benchmark.sh;
      dontUnpack = true;
      nativeBuildInputs = [pkgs.makeWrapper];
      installPhase = ''
        mkdir -p $out/bin
        install -m755 $src $out/bin/beacon-import-and-benchmark
        wrapProgram $out/bin/beacon-import-and-benchmark \
          --prefix PATH : ${pkgs.lib.makeBinPath [pkgs.jq pkgs.unzip beacon]}
      '';
      meta.mainProgram = "beacon-import-and-benchmark";
    };

    # currently no test suite
    # checks.beacon = bc.components.beacon-test;
  };
}
