{
  inputs = {
    # No inputs are used for ‘.lib’ so if all you’re consuming from this flake
    # is the lib don’t worry about these.  You can safely override all these
    # inputs to follow your flake’s inputs so as to minimize transitive flake
    # input explosion without affecting the functionality of the actual .lib.*
    # exports.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    systems.url = "systems";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    # Ok technically this is used for .lib. :) but I assume you can override
    # this, too.
    flake-parts.url = "flake-parts";
  };
  outputs =
    {
      self,
      systems,
      flake-parts,
      nixpkgs,
      ...
    }@inputs:
    let
      pl2nixFlake =
        { ... }:
        {
          flake = {
            lib.package-lock2nix = import ./package-lock2nix.nix;
          };
          perSystem =
            {
              pkgs,
              lib,
              system,
              ...
            }:
            {
              treefmt = import ./nix/treefmt.nix;
              checks =
                let
                  package-lock2nix = pkgs.callPackage self.lib.package-lock2nix { };
                in
                lib.packagesFromDirectoryRecursive {
                  callPackage = lib.callPackageWith (pkgs // { inherit package-lock2nix; });
                  directory = ./tests;
                };
            };
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;
      imports = [
        pl2nixFlake
        inputs.treefmt-nix.flakeModule
      ];
    };
}
