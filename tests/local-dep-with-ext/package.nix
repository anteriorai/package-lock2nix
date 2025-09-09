{
  lib,
  coreutils,
  gnugrep,
  package-lock2nix,
}:

package-lock2nix.mkNpmModule {
  src = ./.;
  doInstallCheck = true;
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
        $out/bin/local-dep-with-ext | tee /dev/stderr | grep -q '^41:hello from transitive external dependency$'
      )
    '';
}
