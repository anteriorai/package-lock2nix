{ package-lock2nix }:

package-lock2nix.mkNpmModule {
  src = ./.;
  npmOverrides = final: prev: {
    "node_modules/bencode" = prev."node_modules/bencode".overrideAttrs {
      postPatch = ''
        echo 'export default { decode: () => "foo" }' > index.js
      '';
    };
  };
}
