# Packages can be built directly from a remote source.

{ package-lock2nix, nodejs_24 }:
let
  repo = builtins.fetchTree "github:anteriorai/brrr/2c2fe952144e01ab367221f074a02c8e6089762c";
  # This package depends on node 24
  package-lock2nix' = package-lock2nix.override { nodejs = nodejs_24; };
in
package-lock2nix'.mkNpmModule { src = "${repo}/typescript"; }
