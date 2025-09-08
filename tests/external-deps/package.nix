{
  lib,
  coreutils,
  gnugrep,
  package-lock2nix,
}:

package-lock2nix.mkNpmModule {
  src = ./.;
  doInstallCheck = true;
  # Hard override the PATH to ensure we’re really testing the embedded PATH in
  # the wrapper script, not any incidental PATH available to the build script
  # itself.
  installCheckPhase =
    let
      testpath = lib.makeBinPath [
        coreutils
        gnugrep
      ];
    in
    ''
      (
        export PATH=${testpath}
        $out/bin/external-deps | tee /dev/stderr | grep -q '^12:hello, world$'
      )
    '';
}
