# You can completely replace a package, without referencing the old one.

{ package-lock2nix, runCommand }:

package-lock2nix.mkNpmModule {
  src = ./.;
  npmOverrides = final: prev: {
    "node_modules/bencode" = runCommand "fake-bencode" { } ''
      mkdir -p $out
      echo {} > $out/package.json
      echo foobar > $out/foo
    '';
  };
  postCheck = ''
    <<<"foobar" diff -u /dev/stdin node_modules/bencode/foo
  '';
}
