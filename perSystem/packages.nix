{
  perSystem = { hsPkgs, ... }:
    let
      bc = hsPkgs.beacon;
    in
    {
      packages.beacon = bc.components.executable;
      
      # currently no test suite
      # checks.beacon = bc.components.beacon-test;
    };
}
