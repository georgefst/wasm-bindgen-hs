{
  description = "Basic Haskell flake";
  inputs = {
    haskell-nix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskell-nix/nixpkgs-2511";
    flake-utils.url = "github:numtide/flake-utils";
    hls-master = { url = "github:haskell/haskell-language-server/master"; flake = false; };
    ghc-wasm-meta.url = "gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org";
    self.submodules = true;
  };
  outputs = inputs@{ self, nixpkgs, flake-utils, haskell-nix, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        overlays = [
          haskell-nix.overlay
          (final: prev: {
            myHaskellProject =
              final.haskell-nix.hix.project {
                src = ./.;
                compiler-nix-name = "ghc914";
                evalSystem = "x86_64-linux";
                shell.nativeBuildInputs = [ inputs.ghc-wasm-meta.packages.${system}.default ];
                shell.tools.cabal = "latest";
                shell.tools.haskell-language-server.src = inputs.hls-master;
                shell.withHoogle = false;
              };
          })
        ];
        pkgs = import nixpkgs { inherit system overlays; inherit (haskell-nix) config; };
      in
      pkgs.myHaskellProject.flake { });
}
