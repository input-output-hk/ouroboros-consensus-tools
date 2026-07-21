{
  perSystem = {hsPkgs, ...}: let
    bc = hsPkgs.beacon;
  in {
    packages.beacon = bc.components.exes.beacon;

    # currently no test suite
    # checks.beacon = bc.components.beacon-test;
  };
}
