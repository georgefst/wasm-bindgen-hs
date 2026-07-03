{
  description = "Basic Haskell flake";
  inputs = {
    haskell-nix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskell-nix/nixpkgs-2511";
    flake-utils.url = "github:numtide/flake-utils";
    hls-master = { url = "github:haskell/haskell-language-server/master"; flake = false; };
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
                crossPlatforms = p: [ p.wasi32 ];
                shell.tools.cabal = "latest";
                shell.tools.haskell-language-server.src = inputs.hls-master;
                shell.withHoogle = false;
                shell.nativeBuildInputs = [
                  (
                    pkgs.writeShellScriptBin "wasm-cabal" ''
                      NIX_LDFLAGS_FOR_TARGET=$(echo "$NIX_LDFLAGS_FOR_TARGET" \
                        | sed 's/ *[^ ]*libffi-[0-9][^ ]* */ /g') \
                      exec wasm32-unknown-wasi-cabal "$@"
                    ''
                  )
                  pkgs.nodejs
                  # Expose the packer as `cabal npm` (via cabal's external
                  # command system) without requiring `cabal install`.
                  (
                    pkgs.writeShellScriptBin "cabal-npm" ''
                      exec cabal run -v0 exe:cabal-npm -- "$@"
                    ''
                  )
                ];
                shell.shellHook = ''
                  export NIX_LDFLAGS=$(echo "$NIX_LDFLAGS" | tr ' ' '\n' | grep -v 'wasm' | tr '\n' ' ')
                '';
              };
          })
        ];
        pkgs = import nixpkgs { inherit system overlays; inherit (haskell-nix) config; };
      in
      pkgs.myHaskellProject.flake { });
}
