{
  description = "A KOReader plugin for taking regular breaks";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nix-update-scripts = {
      url = "github:jwillikers/nix-update-scripts";
      inputs = {
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs";
        pre-commit-hooks.follows = "pre-commit-hooks";
        treefmt-nix.follows = "treefmt-nix";
      };
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nix-update-scripts,
      nixpkgs,
      flake-utils,
      pre-commit-hooks,
      treefmt-nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        pre-commit = pre-commit-hooks.lib.${system}.run (
          import ./pre-commit-hooks.nix { inherit pkgs treefmtEval; }
        );
        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
        # Run the unit tests with the given Lua interpreter.
        mkTests =
          lua:
          pkgs.runCommand "breaktimer-tests-${lua.pname}" { } ''
            ${lua.interpreter} ${self}/test/test_breaktimer.lua
            touch $out
          '';
      in
      with pkgs;
      {
        apps = {
          inherit (nix-update-scripts.apps.${system}) update-nix-direnv update-nixos-release;
        };
        checks = {
          inherit pre-commit;
          # KOReader uses LuaJIT.
          tests-luajit = mkTests luajit;
          tests-lua5_4 = mkTests lua5_4;
        };
        devShells.default = mkShell {
          inherit (pre-commit) shellHook;
          nativeBuildInputs =
            with pkgs;
            [
              asciidoctor
              just
              lua5_4
              luajit
              luajitPackages.luacheck
              lychee
              nushell
              treefmtEval.config.build.wrapper
            ]
            # Make formatters available for IDE's.
            ++ (builtins.attrValues treefmtEval.config.build.programs)
            ++ pre-commit.enabledPackages;
        };
        formatter = treefmtEval.config.build.wrapper;
      }
    );
}
