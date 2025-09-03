{ package-lock2nix }:

package-lock2nix.mkNpmModule {
  src = ./.;
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/single-no-deps | tee /dev/stderr | grep -q '^hello, world$'
  '';
}
