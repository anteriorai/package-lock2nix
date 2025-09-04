{ package-lock2nix }:
package-lock2nix.mkNpmWorkspace {
  root = ../.;
  workspace = "aaa";
  name = "aaa";
}
