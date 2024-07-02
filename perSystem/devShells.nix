{ inputs, ... }: {
  perSystem = { shellFor, pkgs, ... }: {
    devShells.default = shellFor {
      packages = p: [ p.beacon ];

      nativeBuildInputs = [
        pkgs.cairo
        pkgs.jq
        pkgs.gh
        pkgs.pkg-config
      ];

      tools = {
        cabal = "latest";
        ghcid = "latest";
        haskell-language-server = {
          src = inputs.haskellNix.inputs."hls-2.10";
          configureArgs = "--disable-benchmarks --disable-tests";
        };
      };

      shellHook = ''
        export LANG="en_US.UTF-8"

        function parse_git_branch() {
            git branch 2> /dev/null | sed -n -e 's/^\* \(.*\)/(\1)/p'
        }
        export PS1="\n\[\033[1;32m\][nix-shell:\w]\[\033[01;36m\]\$(parse_git_branch)\[\033[0m\]\$ "        
      '';

      withHoogle = true;
    };
  };
}
