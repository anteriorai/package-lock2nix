{ package-lock2nix }:
package-lock2nix.mkNpmWorkspace {
  root = ../.;
  workspace = "bbb";
  name = "bbb";
}
