# package-lock2nix parses NPM lock files to Nix at eval time
# Copyright (C) 2025 Anterior
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, version 3 of the
# License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Parse a package.json and package-lock.json into a built derivation.  This
# module parses the package-lock.json into an eval-time dependency tree to
# download and install every dependency as individual nix derivations.  It links
# them all together into one big final symlink forest, meaning anything that
# uses this folder for its node_modules must run with NODE_PRESERVE_SYMLINKS=1,
# or equivalent (e.g. tsconfig.json’s compilerOptions.preserveSymlinks=true).
# It is npm workspace aware and does treeshaking of dependencies when building
# individual packages for different workspaces.
#
# The API is not set in stone: this works for us, for now, it’s quite ad-hoc, we
# hope to learn about a better API as usage continues.
#
# This module is inspired by:
#
# - https://nmattia.com/posts/2022-12-18-lockfile-trick-package-npm-project-with-nix/
#
# - https://github.com/pyproject-nix/uv2nix
#
# It’s more involved than the former, and less featureful than the latter.

{
  fetchurl,
  findutils,
  jq,
  lib,
  makeWrapper,
  newScope,
  nodejs,
  plan9port,
  runCommand,
  stdenv,
  stdenvNoCC,
  writeShellApplication,
  writeShellScript,
  writeScript,
  writeTextFile,
  writeText,

  # Optional dependency required for workspaces
  globset ? null,

  # Overlay to apply.  This file returns a lambda which is callable using
  # callPackage, which itself returns a scope.  You could use .overrideScope on
  # that as a user, but it would ruin the ability to call .override on that
  # result to modify the original callPackage args.  This argument will be
  # passed to .overrideScope internally in this module before returning it,
  # meaning you can specify an overlay while preserving the ability to call
  # .override on the result.
  overrideScope ? final: prev: { },
}:

let
  scope = lib.makeScope newScope (
    scopeSelf:
    let
      # horrific script which should never be used: recursively replace every
      # absolute symlink in this directory by a copy of its target.  Obviously
      # _extremely_ dangerous, particularly in a devShell (which is why it’s not
      # exposed in nativeBuildInputs).
      unsymlinkify = writeShellApplication {
        name = "unsymlinkify";
        meta.description = "In given directory recursively replace each symlink with its target";
        runtimeInputs = [ findutils ];
        text =
          let
            replaceSymlink = writeShellScript "replace_symlink" ''
              set -euo pipefail
              target="$(readlink -f "$1")"
              # Only interested in directories (we're hacking
              # non-preserveSymlinks-conforming software)
              if [[ -d "$target" ]]; then
                rm -f "$1"
                cp --no-preserve=ownership -r "$target" "$1"
                # We _do_ want to preserve the executable bit
                chmod -R u+w "$1"
              elif [[ ! -f "$target" ]]; then
                >&2 echo "No target file found at $target for link $1"
                exit 1
              fi
            '';
          in
          # White-listed possible build directories just because of how dangerous
          # this script is when accidentally run in the wrong location during dev
          # or debugging.
          ''
            if [[ "$PWD" != /tmp/* && "$PWD" != /private/tmp/* && "$PWD" != /var/* && "$PWD" != /build/* && "$PWD" != /nix/var/nix/builds/* ]]; then
              >&2 cat <<EOF
            Dangerous script 'unsymlinkify' running in unexpected build directory
            $PWD, refusing to continue.  Edit the whitelist in package-lock2nix
            source to circumvent this.
            EOF
              exit 1
            fi
            find "$1" -mindepth 1 -maxdepth 1 -type l -lname '/*' -exec ${replaceSymlink} {} \;
            me="''${BASH_SOURCE[0]}"
            find "$1" -mindepth 1 -maxdepth 1 -type d -exec "$me" {} \;
          '';
      };

      # createDeepLinks SOURCE_ROOT TARGET_ROOT
      #
      # links :: [ { source : str; target : str; } ]
      #
      # Creates a script which, when run, accepts two arguments, and will link all
      # ‘source’ entries from the first (runtime) argument into their ‘target’ in
      # the second (runtime) argument.  This can be used to create a “symlink
      # forest”.
      #
      # Force passing an explicit "root" directory for the relative links as an
      # argument because creating relative links in arbitrary nested directories is
      # not (never?) what we want.
      createDeepLinks =
        links:
        writeShellScript "create-links" (
          ''
            set -euo pipefail
          ''
          + lib.concatMapStringsSep "\n" (
            { source, target }:
            ''
              mkdir -p "$1/"${lib.escapeShellArg (builtins.dirOf target)}
              ln -s "$1/"${lib.escapeShellArg source} "$1/"${lib.escapeShellArg target}
            ''
          ) links
        );

      # Like rm -f, but also recursively remove any now-empty directories after
      # removing the files.  This is the complement to a routine which created these
      # files and used mkdir -p on all their parent directories before placing them.
      rmFilesAndCleanupDirs =
        files:
        writeShellScript "rm-files-and-cleanup-dirs" (
          ''
            set -euo pipefail
          ''
          + lib.concatMapStringsSep "\n" (
            file:
            ''
              rm -f "$1/"${lib.escapeShellArg file}
            ''
            + (
              let
                # Hack: rely on rmdir’s only-delete-if-empty behavior.
                f =
                  dir:
                  lib.optionalString (dir != ".") (
                    ''
                      rmdir "$1/"${lib.escapeShellArg dir} &>/dev/null || true
                    ''
                    + (f (builtins.dirOf dir))
                  );
              in
              f (builtins.dirOf file)
            )
          ) files
        );

      # Parse binary names and paths from a package-lock.json.  Not done because we
      # don’t use it but one day someone might want to: directories.bin.
      outBins =
        packageJson:
        let
          bins = packageJson.bin or { };
        in
        if builtins.typeOf bins == "string" then { ${packageJson.name} = bins; } else bins;

      # Unpack a single NPM dependency tarball.  This is a prime target for
      # overriding through an overlay, so honor stdenv expectations: idiomatic
      # phases, post* and pre* hooks, ...
      mkNodeSingleDep = lib.makeOverridable (
        {
          name,
          src,
          version,
        }:
        stdenv.mkDerivation (self: {
          inherit name src version;
          # The plan9 tar is more robust against poorly crafted archives.  Otherwise
          # you get this:
          # https://discourse.nixos.org/t/unpack-phase-permission-denied/13382/4
          plan9UnpackPhase = ''
            unpackFile() {
              ${plan9port}/plan9/bin/tar xf "$1"
              rm -rf PaxHeader
            }
          '';
          prePhases = [ "plan9UnpackPhase" ];
          # Don’t build by default to prevent stdenv picking up a dependency’s
          # makefile and start building.  That has to be opt-in.
          dontBuild = true;
          nativeBuildInputs = [ jq ];
          # Many launcher scripts use the #!/usr/bin/env node shebang which is best
          # pinned at fixup time of this derivation to a specific nodejs version.
          buildInputs = [ nodejs ];
          installPhase = ''
            runHook preInstall

            cp -r . "$out"

            runHook postInstall
          '';
          # You cannot trust the permissions in the tar file so it’s better to force
          # everything to 644 and only set the executable bit on directories and files
          # which we know explicitly to be listed as executables.
          forcePermissionsPhase = ''
            <"$out/package.json" jq -r '(.name as $name | .bin | if type == "object" then (to_entries | .[].value) else . end) // empty' | while read path; do
              chmod +x $out/$path
              patchShebangs $out/$path
            done
          '';
          preFixupPhases = [ "forcePermissionsPhase" ];
        })
      );

      # Download dependencies from a (pre-parsed) package-lock.json into
      # node_modules directory.  This doesn’t _build_ a project it just gets its
      # dependencies.  That works because the NPM convention is to host all packages
      # fully built and ready to load on NPM.  Notable exception: if any of those
      # dependencies are local, aka "lib" folders in the same repo, they _will_ be
      # built because those are not expected to be checked into source pre-built.
      #
      # This also doesn’t care about workspaces, nor devDependencies vs non-dev:
      # that’s the job of the caller.  This function just takes a list of
      # dependencies-to-download, and downloads those.
      #
      # LinkSpec = { link : Boolean; resolved : String; }
      # FetchSpec = { resolved: String; integrity : String; hierarchy: [ String ] }
      # packages :: { String : LinkSpec | FetchSpec }
      mkNodeModules'' =
        {
          # Used only for linked (local) dependencies
          root,
          name,
          packages,
          srcOverrides,
        }:
        assert lib.assertMsg (packages != { }) "Cannot make node_modules for empty packages";
        let
          sourcesFlatRaw = builtins.mapAttrs (
            name: p:
            (
              if (p.link or false) then
                scopeSelf.mkNpmModule {
                  src = root + ("/" + p.resolved);
                  npmOverrides = srcOverrides;
                }
              else
                mkNodeSingleDep {
                  src = fetchurl {
                    url = p.resolved;
                    hash = p.integrity;
                  };
                  name = lib.last p.hierarchy;
                  inherit (p) version;
                }
            ).overrideAttrs
              (old: {
                passthru = old.passthru or { } // {
                  inherit (p) hierarchy;
                };
              })
          ) packages;
          # Apply the override fixpoint on the _flat_ source list, not the exploded &
          # merged source tree.  This means an override for a top-level package and
          # nested package will be completely separate and must be defined separately.
          # It would probably be technically better to this the other way around but
          # also harder, I think.
          sourcesFlat' = lib.fix (lib.extends srcOverrides (_: sourcesFlatRaw));
          # Trick to ignore overlay items which are unused by this particular
          # derivation.  This allows specifying one giant shared overlay for your
          # entire workspace without checking if each individual element in the
          # overlay is actually present in the ‘prev’.  It’s not always necessary
          # for a fixpoint, but we end up doing a greedy evaluation of all attribute
          # names of this fixpoint, which crashes if the overlay tries to access
          # unknown items on the prev.
          sourcesFlat = builtins.intersectAttrs sourcesFlatRaw sourcesFlat';
          sources = lib.foldl' lib.recursiveUpdate { } (
            lib.mapAttrsToList (path: deriv: lib.setAttrByPath deriv.hierarchy { "." = deriv; }) sourcesFlat
          );
          walkSources =
            a:
            let
              recursed = builtins.mapAttrs (_: walkSources) a;
              # This is a bundle of multiple dependencies for this path in the
              # node_modules.  Create a new derivation which wraps them all up into a
              # single folder which can be linked by its parent.  The most typical
              # example for this is the top-level node_modules folder itself, which is
              # a folder containing a ton of symlinks.  However some of its folders
              # may have nested dependencies, so they can’t be symlinks to the
              # original downloads, but must be freshly constructed dependencies which
              # end up being a single folder which itself can be symlinked into
              # node_modules.  Just like that final big node_modules directory can be
              # symlinked into its parent :).  Don’t use the package-lock’s name
              # because _who knows_ this could just be reusable by another project.
              combined = stdenvNoCC.mkDerivation {
                name = "node-modules-batch";
                dontUnpack = true;
                dontBuild = true;
                nativeBuildInputs = [
                  jq
                  makeWrapper
                ];
                installPhase = ''
                  runHook preInstall

                  mkdir -p $out
                ''
                + lib.concatStringsSep "\n" (
                  lib.mapAttrsToList (n: v: ''
                    ln -s ${v} $out/${lib.escapeShellArg n}
                  '') recursed
                )
                +
                  # makeRelativeWrapper is a horrible variant of makeWrapper
                  # (without any of the flags) which respects relative paths to the
                  # link, at invocation time.  The resulting binary acts like a
                  # symlink without actually being a symlink.  It doesn’t touch the
                  # working dir, it just finds the target script /relative/ to the
                  # wrapper script and execs into that.  You can’t do a simple ‘exec
                  # ../../my/target.sh’ because those ../.. are interpreted relative
                  # to the working directory of the caller, not the wrapper script.
                  # And why not a normal symlink?  Because the node.js ecosystem is
                  # in a horrible state of symlink support: node has two flags,
                  # --preserve-symlinks and --preserve-symlinks-main: the former is
                  # for regular require/import calls in node.js code, the latter is
                  # an entirely separate flag to support preserving symlinks _of the
                  # entrypoint_.  That isn’t default because so many node.js
                  # packages actually _expect_ non-preservation of symlinks for
                  # their entrypoint, because they _expect_ to be symlinked from
                  # node_modules/.bin/foo-pkg -> node_modules/foo-pkg/main.js.  In
                  # main.js they’ll do things like ‘require("./utils.js")’ which
                  # would fail if you actually preserved symlinks (there is no
                  # node_modules/.bin/utils.js).  Even npm and npx themselves break
                  # if you set that flag to true, so you really can’t do it at
                  # derivation level.
                  #
                  # This is all compounded by the obsolesence of NODE_PATH: node.js
                  # really only works reliably if all dependencies are in
                  # <rootDir>/node_modules/*.  If you take the “default” route:
                  #
                  #   - node_modules/.bin/foo-pkg is a symlink -> ../foo-pkg/main.js
                  #   - node_modules/foo-pkg is itself a symlink -> /nix/store/...-foo-pkg/
                  #   - NODE_PRESERVE_SYMLINKS=1
                  #   - NODE_PRESERVE_SYMLINKS_MAIN is unset
                  #
                  # then foo-pkg/main.js will be found, but will be called as
                  # /nix/store/...-foo-pkg/main.js, so it won’t find any sister
                  # dependencies which it declared it needed.  There is only one
                  # reliable way to handle dependencies, it’s not NODE_PATH: when
                  # you call foo-pkg/main.js, node /must/ call it as
                  # <rootDir>/node_modules/foo-pkg/main.js, aka: all symlinks in the
                  # entire chain must be preserved.  That means you must enable
                  # NODE_PRESERVE_SYMLINKS and NODE_PRESERVE_SYMLINKS_MAIN, but
                  # node.js must be aware (somehow) that the entrypoint script is
                  # called from <rootDir>/node_modules/foo-pkg/main.js instead of
                  # <rootDir>/node_modules/.bin/foo-pkg: that is achieved by this
                  # insane wrapper.
                  #
                  # - https://github.com/nodejs/node/issues/19383
                  #
                  # 😰
                  ''

                    makeRelativeWrapper() {
                      set -eu
                      >"$2" cat <<EOF
                    #!$shell
                    set -eu
                    export NODE_PRESERVE_SYMLINKS_MAIN=1
                    d="\$(dirname "\''${BASH_SOURCE[0]}")"
                    exec "\$d/$1" "\$@"
                    EOF
                      chmod +x "$2"
                    }
                    (
                      cd $out
                      set -eu
                      shopt -s nullglob
                      for d in */ @*/*/ ; do
                        if [[ -f "$d"package.json ]]; then
                          <"$d/package.json" jq -r '.name as $name | (.bin // empty) | if type == "object" then . else {"\($name)": .} end| to_entries | .[]| [.key, .value] | @tsv' | while read -r binname path; do
                            mkdir -p .bin
                            (
                              cd .bin
                              target="../''${d}$path"
                              src="''${binname##*/}"
                              makeRelativeWrapper "$target" "$src"
                            )
                          done
                        fi
                      done
                    )

                    runHook postInstall
                  '';
                # Useful for debugging individual dependencies using nix develop.
                passthru.packages = sourcesFlat;
                # 🐉 script which merges these node modules into the current
                # directory: creates a symlink if no pre-existing directory exists
                # by the given name, otherwise the directory is entered and the
                # contents are merged into it, recursively.  Use this after
                # preparing nested symlinks in a sparse node_modules directory to
                # fill in the "rest".
                passthru.mergeInto = writeShellScript "merge-node-modules" (
                  ''
                    set -euo pipefail
                    # Yes lazy evaluation and deteriministic derivation out path
                    # hashes save me here.
                    if [[ -d ${combined}/.bin ]]; then
                      cp -r ${combined}/.bin "$1"/
                    fi
                  ''
                  + lib.concatLines (
                    (lib.mapAttrsToList (
                      n: v:
                      let
                        base = lib.escapeShellArg (builtins.baseNameOf n);
                      in
                      (
                        # Insane magic but the problem is I can’t do this in pure
                        # bash because if there is no ‘v.mergeInto’ property, then I
                        # can’t even _generate_ the bash ‘then-clause’, even if the
                        # actual bash if-statement would somehow ignore it.
                        lib.optionalString (v ? mergeInto) ''
                          [[ -d "$1/"${base} ]] &&
                          ${v.mergeInto} "$1/"${base} || ''
                        # If this isn’t a merge-into script then just link it, no
                        # matter what.
                        + ''ln -s ${v} "$1/"${lib.escapeShellArg n}''
                      )
                    ) recursed)
                  )
                );
              };
              output =
                if (builtins.attrNames a == [ "." ]) then
                  # a is just a single leaf dependency. Include it directly.
                  a."."
                else if a ? "." then
                  # a is a collection of dependencies with at least the "."
                  # path, which is the foldl’s base case to indicate "the
                  # current directory".  That means the output must be a
                  # derivation with those files in the current directory.  If a
                  # also has other entries, which aren’t "." but “real paths”,
                  # those should be included.
                  let
                    nestedDependencies = builtins.removeAttrs recursed [ "." ];
                  in
                  a.".".overrideAttrs (old: {
                    linkNestedDependenciesPhase = lib.concatStringsSep "\n" (
                      lib.mapAttrsToList (name: path: ''
                        ln -s ${path} ${lib.escapeShellArg name}
                      '') nestedDependencies
                    );
                    # This must happen before (potential) building
                    preConfigurePhases = old.preConfigurePhases or [ ] ++ [ "linkNestedDependenciesPhase" ];
                  })
                else
                  combined;
            in
            # Assumption: we never get a package-lock that tries to create empty
            # directories.
            assert a != { };
            # Invariant: walkSources always returns a derivation
            assert lib.assertMsg (lib.isDerivation output)
              "walkSources output non-deriv for ${builtins.toString (builtins.attrNames a)}: ${output}";
            output;
          nodeModules = walkSources sources;
        in
        nodeModules.overrideAttrs {
          nativeBuildInputs = [ makeWrapper ];
          npmDontMakeBin = true;
          # Binaries left in node_modules/.bin by npm expect:
          #
          # - to be able to load from JS any module from the parent node_modules
          #
          # - to be able to find any other sibling binary on the PATH
          #
          # (I think.  At least it seemed like it.  These now definitely can do that.)
          fixupPhase = ''
            nmbin=$out/node_modules/.bin
            if [[ -d $nmbin && -z "''${npmDontMakeBin-}" ]]; then
              (
                cd $nmbin
                for f in * ; do
                  makeWrapper $PWD/$f $out/bin/$f \
                    --suffix PATH : $out/bin
                done
              )
            fi
          '';
        };

      mkNodeModules' =
        { packages, ... }@args:
        if
          packages == { }
        # Hack to support package-lock without any dependencies.
        # Technically this is “too late”: real npm on a
        # package-lock.json without any dependencies doesn’t even create
        # a node_modules directory at all.  To emulate that, upstream
        # users of this function should be able to handle a missing
        # node_modules directory.
        then
          runCommand "empty-node_modules"
            {
              # nodeModules derivations have an ad-hoc collection of helper
              # scripts defined in passthru.  Again, a better way to do this is to
              # just support missing node_modules directories in the caller, but
              # for now this works.
              passthru = {
                cleanupLinks = "true";
                createLinks = "true";
                mergeInto = "true";
              };
            }
            ''
              mkdir -p $out/node_modules
            ''
        else
          mkNodeModules'' args;

    in
    {
      # Create a non-workspace node_modules folder from a package-lock.json file in
      # this folder.  Should work with local dependencies (file:...) although that’s
      # poorly tested.
      mkNodeModules = lib.makeOverridable (
        {
          root,
          packageLock,
          installDev,
          srcOverrides,
        }@args:
        let
          # Best effort parsing a package-lock.json file.
          filtered = lib.filterAttrs (
            name: p:
            (
              # I think this means the dependency is provided nested, by the package itself?
              (!(p.inBundle or false))
              &&
                # Only install dev dependencies if we need them
                ((p.dev or false) -> installDev)
              &&
                # Some weird meta object representing the original package.json file
                (name != "")
              &&
                # The actual link to the remote archive to download
                (p ? resolved)
            )
          ) packageLock.packages;
          explode =
            sep: s: inner:
            lib.foldr (n: a: { ${n} = a; }) inner (lib.splitString sep s);
        in
        mkNodeModules' {
          # Get the name from the package-lock.json, NOT from the caller, to allow
          # reusing the same underlying dependency for derivations which share the
          # same package-lock.  These can get heavy (easily >1GiB) so this is worth
          # it.
          inherit (packageLock) name;
          inherit root srcOverrides;
          packages = builtins.mapAttrs (
            path: lib.mergeAttrs { hierarchy = lib.splitString "/" path; }
          ) filtered;
        }
      );

      # Unlike its non-workspace counterpart this does _not_ build local
      # dependencies.  This merely prepares a copy of the root folder structure but
      # with only the relevant node_modules directories for this workspace.
      mkWorkspaceNodeModules = lib.makeOverridable (
        {
          root,
          workspace,
          packageLock,
          installDev,
          srcOverrides,
        }@args:
        assert lib.assertMsg (globset != null) "workspaces require the globset arg";
        let
          fileset = globset.lib.globs root (
            lib.concatMap (p: [
              "${p}/package.json"
              "${p}/package-lock.json"
            ]) ([ "." ] ++ (packageLock.packages."".workspaces or [ ]))
          );
          src = lib.fileset.toSource {
            inherit root;
            inherit fileset;
          };
          packages = builtins.mapAttrs (
            path: lib.mergeAttrs { hierarchy = lib.splitString "/" path; }
          ) packageLock.packages;
          # Sneaky way to discover all workspaces in the lock file: they seem to be
          # the only packages that don’t live in a node_modules folder.  Don’t know if
          # this is by spec at all but it saves me a complicated recursive tree fold.
          isWorkspaceDir = dir: dir != "" && !(lib.hasInfix "node_modules" dir);
          # allWorkspaces :: { name :: dir }
          #
          # This map is useful because packages are "keyed" in the package-lock.json
          # by their directory but they are identified in a dependency list by their
          # package name.
          allWorkspaces = lib.concatMapAttrs (
            dir: value: lib.optionalAttrs (isWorkspaceDir dir) { ${value.name} = dir; }
          ) packageLock.packages;
          isWorkspaceName = name: builtins.hasAttr name allWorkspaces;
          # Simple, flat list of dependency names for this spec.
          getDepNames =
            spec:
            map
              (name: {
                inherit name;
                optional = false;
              })
              (
                (builtins.attrNames spec.dependencies or { })
                ++ lib.optionals installDev (builtins.attrNames spec.devDependencies or { })
              )
            ++
              # TODO: make this configurable?
              # https://nodejs.org/en/blog/npm/peer-dependencies
              map
                (name: {
                  inherit name;
                  optional = true;
                })
                (
                  # Should we include peerDependencies here?
                  (builtins.attrNames spec.peerDependencies or { })
                  ++ (builtins.attrNames spec.optionalDependencies or { })
                );
          # Given a location in the full package tree, find the “closest” sibling
          # with this name.
          #
          # package-lock.json dependencies look something like this:
          #
          #   "node_modules/@stoplight/spectral-core/node_modules/@stoplight/better-ajv-errors": {
          #     "version": "1.0.3",
          #     "resolved": "https://registry.npmjs.org/@stoplight/better-ajv-errors/-/better-ajv-errors-1.0.3.tgz",
          #     "integrity": "sha512-0p9uXkuB22qGdNfy3VeEhxkU5uwvp/KrBTAbrLBURv6ilxIVwanKwjMc41lQfIVgPGcOkmLbTolfFrSsueu7zA==",
          #     "license": "Apache-2.0",
          #     "dependencies": {
          #       "jsonpointer": "^5.0.0",
          #       "leven": "^3.1.0"
          #     },
          #     "engines": {
          #       "node": "^12.20 || >= 14.13"
          #     },
          #     "peerDependencies": {
          #       "ajv": ">=8"
          #     }
          #   },
          #
          # Note how the dependencies are just identified by name.  This is not
          # enough to deterministically point at _where_ exactly in the
          # package-lock.json that dependency can be found, e.g. ‘leven’: is it a
          # sibling of ‘@stoplight/better-ajv-errors’ here?  Or is it found all the
          # way top-level?  To find out you must walk backwards through every layer
          # until you find an entry by that name.  That’s this function.
          getDep' =
            hierarchy: name:
            let
              d = lib.concatStringsSep "/" (
                hierarchy
                ++ [
                  "node_modules"
                  name
                ]
              );
            in
            if builtins.hasAttr d packages then
              d
            else if hierarchy == [ ] then
              null
            else
              getDep' (lib.init hierarchy) name;
          # "node_modules/foo/node_modules/bar/...", or null
          getDep = spec: name: allWorkspaces.${name} or (getDep' spec.hierarchy name);
          # like builtins.map but remove any null values
          notNullMap = f: xs: builtins.filter (x: x != null) (map f xs);
          # Still no recursion: just get every dep path for this specific spec.  If
          # optional, missing dependencies are ignored.  If non-optional, missing
          # dependencies cause an eval error.
          getDeps =
            # This optional indicates whether this entire node is itself inluded in
            # an optional context or not.
            { optional, spec }@outer:
            # Every dependency can indicate whether it is optional or not.
            notNullMap (
              { name, optional }@inner:
              let
                path = getDep spec name;
                # This dependency is optional if either it is explicitly marked as an
                # optional dependency, or it finds itself in a dependency chain with
                # at least one optional parent.  N.B.: package-lock.json has a
                # “optional” attribute on individual specs which is _invalid_.  That
                # attribute is from a pre-workspaces era, but in a workspaces world
                # you cannot tell whether a dependency spec, in isolation, is optional
                # or not: that only makes sense in the context of a workspace.  This
                # is a bug in package-lock.json semantics, which is why that field is
                # ignored here.
                actuallyOptional = outer.optional || inner.optional;
              in
              assert lib.assertMsg (
                (path == null) -> actuallyOptional
              ) "Couldn't find non-optional dependency ${name} of ${lib.concatStringsSep "/" spec.hierarchy}";
              if path == null then
                null
              else
                {
                  optional = actuallyOptional;
                  inherit path;
                }
            ) (getDepNames spec);
          # Collect all dependencies of this path, inclusive.
          #
          # Would have returned a set if that were an option, but nix doesn’t have
          # sets, so we use attrsets with values always set to null.  This function
          # is intended for a fold operation.  You pass this _down_ into nested
          # layers of dependencies, each of which adds all of its dependencies to
          # the accumulator.
          allPackages' =
            acc:
            { path, optional }:
            let
              children = getDeps {
                inherit optional;
                spec = packages.${path};
              };
            in
            if acc ? ${path} then acc else lib.foldl' allPackages' (acc // { ${path} = null; }) children;
          # Utility function for the above to hide its “fold accumulator” nature.
          allPackages =
            path:
            builtins.attrNames (
              allPackages' { } {
                inherit path;
                optional = false;
              }
            );
          allMyPackages = allPackages workspace;
          allMyDependencies = builtins.filter (n: !isWorkspaceDir n) allMyPackages;
          directWorkspaceDeps =
            dir:
            lib.concatMap (x: lib.optional (allWorkspaces ? ${x.name}) allWorkspaces.${x.name}) (
              getDepNames packages.${dir}
            );
          # Separate map for my workspace dependencies sorted topologically (with
          # duplicates)
          workspaceDependencies = lib.fix (
            self:
            lib.concatMapAttrs (_: dir: {
              ${dir} = lib.concatMap (x: self.${x}) (directWorkspaceDeps dir) ++ [ dir ];
            }) allWorkspaces
          );
          includedWorkspaces = lib.unique workspaceDependencies.${workspace};
          nodeModules = mkNodeModules' {
            inherit (packageLock) name;
            inherit srcOverrides;
            root = src;
            packages = lib.getAttrs allMyDependencies packages;
          };
        in
        nodeModules.overrideAttrs (
          old:
          let
            links = (
              builtins.filter (x: x != null) (
                lib.mapAttrsToList (
                  dir: spec:
                  let
                    linkToActiveWorkspace =
                      (spec.link or false) && builtins.elem (spec.resolved or "") includedWorkspaces;
                  in
                  if linkToActiveWorkspace then
                    {
                      source = spec.resolved;
                      target = dir;
                    }
                  else
                    null
                ) packages
              )
            );
          in
          {
            passthru = old.passthru or { } // {
              # most of this is just for debugging
              inherit
                allWorkspaces
                includedWorkspaces
                packageLock
                allMyDependencies
                ;
              excludedWorkspaces = lib.subtractLists includedWorkspaces (builtins.attrValues allWorkspaces);
              # A stand-alone script to create symlinks to linked entries (other
              # workspaces hopefully)
              createLinks = createDeepLinks links;
              # Remove all symlinks created by the createLinks script from the working
              # directory.
              cleanupLinks = rmFilesAndCleanupDirs (map ({ source, target }: target) links);
            };
          }
        )
      );

      # Build an NPM package from a package-lock.json which is expected to place its
      # final outputs in dist/.
      mkNpmModule =
        {
          src,
          packageLock ? builtins.fromJSON (builtins.readFile (src + "/package-lock.json")),
          # I think there is a better way to do this but I’m too grug
          npmOverrides ? self: super: { },
          ...
        }@args:
        let
          final = stdenv.mkDerivation (
            self:
            let
              packageJson = builtins.fromJSON (builtins.readFile (src + "/package.json"));
            in
            {
              inherit (packageLock) name;
              nodeModules = scopeSelf.mkNodeModules {
                inherit packageLock;
                root = src;
                # This whole time I thought it would be worth it to create a
                # separate node_modules for dev and non-dev; build the app with dev,
                # then swap in the non-dev on install.  Turns out no project of any
                # complexity is compatible with this: they keep references to the
                # dev node_modules around, defeating treeshaking, and you end up
                # with almost _double_ the dependencies rather than fewer.  I guess
                # the normal way to do this is to build with devDependencies, then
                # on install _remove_ all dev-only dependencies from node_modules?
                # Of course that cannot work in Nix.  This should be solved more
                # properly, but for now let’s just pretend in the rest of the file
                # that anyone still want separate prod and dev nodeModules.
                installDev = true;
                srcOverrides = npmOverrides;
              };
              devNodeModules = self.nodeModules.override { installDev = true; };
              # Start with dev modules regardless because they are usually required
              # for building
              patchPhase = ''
                runHook prePatch

              ''
              # Technically these are pretty much default, but when a script gets
              # launched directly from one of the symlinked dependencies
              # (e.g. jest), it won’t "know" where it "came from" because by default
              # those aren’t launched symlink aware.  Set the PATH here to the
              # build-dir location, instead of setting it to
              # e.g. PATH="$nodeModules/.bin".  Completely avoid NODE_PATH.
              #
              # - NODE_PATH is a second class citizen in nodejs and has poor support
              #   from newer features, e.g. es modules.
              #
              # - The nix build will fail if it finds any reference to the build
              #   path in the final derivation.  This solution _increases_ the
              #   likelihood of that happening if, par malheur, some part of this
              #   build decides to hard-code this PATH in an output file.  In that
              #   case we’d _want_ an error, but if you use PATH=/nix/store/..., all
              #   that happens is the dev node_modules now silently become a
              #   permanent runtime dependency of the final derivation output.
              #   Better to fail loudly.
              #
              # - This is more like a "real" build because a "real" build also just
              #   expects your NODE_PATH to basically be <build_dir>/node_modules
              #   (which it is by default, just not symlink aware).
              + ''
                ln -s $devNodeModules/node_modules
                addToSearchPath PATH "$PWD/node_modules/.bin"

                runHook postPatch
              '';
              nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
                nodejs
                makeWrapper
                # DO WHAT YOU CAN TO AVOID USING THIS!  It is a massive crutch.
                unsymlinkify
              ];
              NODE_PRESERVE_SYMLINKS = 1;
              # npm will ensure the final binaries are executable for you, though at a
              # weird moment: not when you build the original package, but when someone
              # ultimately installs it.  That causes these files to get symlinked into
              # their ./node_modules/.bin/ directory (or globally), at which point npm
              # will ensure they’re chmod +x.  So we might as well just do it right here.
              buildPhase = ''
                runHook preBuild

                npm run build

                runHook postBuild
              '';

              doCheck = true;
              npmCheckTarget = "test";
              checkPhase = ''
                runHook preCheck

                npm run $npmCheckTarget

                runHook postCheck
              '';

              # Is this the best way to do it? Certainly not.
              installPhase = ''
                runHook preInstall

                rm node_modules
                mkdir -p $out
                cp -r . $out/
                ln -s $nodeModules/node_modules $out/

                runHook postInstall
              '';

              # Tests on nixbuild.net were failing with OOM error and while it sometimes
              # works on the local linux-builder and I’m sure there’s some kind of cool
              # modern way to get Node.js to take its memory size from some kind of runner
              # config this also works so w/e just do this.
              #
              # N.B.: This only works for node.js runs that are actually executed during a
              # nix build: building and testing.  This doesn’t apply to the user actually
              # running a service itself.  Remember: Nix is only for _build time_, not
              # runtime.  Runtime you end up with a raw executable which needs its own
              # wrapping.  That’s fine here because the problem was unit tests in the
              # first place but it’s good to keep in mind.
              NODE_OPTIONS = "--max-old-space-size=6000";

              fixupNpmBinaries =
                let
                  # Reverse hack: _if_ your package depends on npm and/or npx at
                  # runtime (some packages do this e.g. for version checks) then it
                  # would break from within a package-lock2nix built derivation,
                  # because npm and npx are not compatible with
                  # NODE_PRESERVE_SYMLINKS_MAIN=1.  This pass detects whether there
                  # is a nodejs derivation in your buildinputs, and before putting
                  # it on the baked PATH of any dependent binary it inserts a
                  # wrapped version of npm and npx which does nothing but disable
                  # that envvar.
                  symlinkSafeNpmNpx =
                    nodejs:
                    stdenvNoCC.mkDerivation {
                      inherit (nodejs) version;
                      pname = "npm-npx";
                      dontUnpack = true;
                      nativeBuildInputs = [ makeWrapper ];
                      installPhase = ''
                        mkdir -p $out/bin
                        cd "${lib.getBin nodejs}/bin"
                        for f in npm npx; do
                          makeWrapper "${lib.getBin nodejs}/bin/$f" "$out/bin/$f" \
                            --unset NODE_PRESERVE_SYMLINKS_MAIN
                        done
                      '';
                    };
                  isNodeJs = drv: (drv.pname or "") == "nodejs";
                  buildInputs' = lib.concatMap (
                    drv: lib.optionals (isNodeJs drv) [ (symlinkSafeNpmNpx drv) ] ++ [ drv ]
                  ) (self.buildInputs or [ ]);
                  PATH = lib.concatStringsSep ":" ([
                    "$out/node_modules/.bin"
                    (lib.makeBinPath buildInputs')
                  ]);
                  script = lib.concatStringsSep "\n" (
                    lib.mapAttrsToList (
                      name: val:
                      let
                        name' = lib.escapeShellArg name;
                        val' = lib.escapeShellArg val;
                      in
                      ''
                        if [[ -f $out/${val'} ]]; then
                          mkdir -p $out/bin
                          chmod +x $out/${val'}
                          patchShebangs $out/${val'}
                          makeWrapper $out/${val'} $out/bin/${name'} \
                            --prefix PATH : ${PATH} \
                            --set-default NODE_PRESERVE_SYMLINKS 1
                        fi
                      ''
                    ) self.passthru.outBins
                  );
                in
                if
                  script == ""
                # stdenv doesn’t like empty phases
                then
                  "true"
                else
                  script;
              preFixupPhases = (args.preFixupPhases or [ ]) ++ [ "fixupNpmBinaries" ];

              passthru = {
                inherit packageLock;
                outBins = outBins packageJson;
              }
              // (args.passthru or { });
              # meta.mainProgram is a nix convention to make lib.getExe find the
              # "main" binary for a derivation (because any derivation can have
              # multiple outputs in its bin/ directory).  If there are multiple
              # entries but one of them happens to have the name of the package,
              # that’s probably the main program.  If there is only one entry, as a
              # string, like "bin": "foo-bar", then the function outBins
              # automatically converts it to an object with one entry, the key being
              # the name of the package itself, so that will also automatically be
              # set as the mainProgram 👍.
              meta =
                lib.optionalAttrs (self.passthru.outBins ? ${self.name}) { mainProgram = self.name; }
                // (args.meta or { });
            }
            // (lib.filterAttrs (n: _: n == "version") packageLock)
            // (builtins.removeAttrs args [
              "nativeBuildInputs"
              "passthru"
              "packageLock"
              "preFixupPhases"
              "npmOverrides"
            ])
          );
        in
        final;

      # build an NPM workspace package and all its dependencies.
      mkNpmWorkspace =
        {
          root,
          workspace,
          includePaths ? [ ],
          npmOverrides ? self: super: { },
          ...
        }@args:
        let
          packageLock = builtins.fromJSON (builtins.readFile (root + /package-lock.json));
          nodeModules = scopeSelf.mkWorkspaceNodeModules ({
            inherit root workspace packageLock;
            installDev = true; # see non-workspace nodeModule for why this is hard
            srcOverrides = npmOverrides;
          });
          orig = scopeSelf.mkNpmModule (
            {
              inherit packageLock;
              src =
                with lib.fileset;
                toSource {
                  inherit root;
                  fileset = unions (
                    [
                      (root + /package.json)
                      (root + /package-lock.json)
                    ]
                    ++ includePaths
                    ++ map (dir: root + "/${dir}") nodeModules.includedWorkspaces
                  );
                };
            }
            // (builtins.removeAttrs args [
              "root"
              "workspace"
              "npmOverrides"
            ])
          );
          final = orig.overrideAttrs (self: {
            inherit nodeModules;
            devNodeModules = nodeModules;
            passthru = (self.passthru or { }) // {
              outBins = builtins.mapAttrs (_: bin: "${workspace}/${bin}") (
                outBins (builtins.fromJSON (builtins.readFile (root + "/${workspace}/package.json")))
              );
            };
            patchPhase = ''
              runHook prePatch

              ${nodeModules.createLinks} "$PWD"
              ${nodeModules.mergeInto} "$PWD"
              addToSearchPath PATH "$PWD/node_modules/.bin"

              runHook postPatch
            '';
            buildPhase = ''
              runHook preBuild

              for w in ${lib.escapeShellArgs nodeModules.includedWorkspaces}; do
                echo "npm build workspace $w"
                npm run --workspace "$w" build
              done

              runHook postBuild
            '';
            checkPhase = ''
              runHook preCheck

              for w in ${lib.escapeShellArgs nodeModules.includedWorkspaces}; do
                echo "npm check workspace $w"
                npm run --workspace "$w" $npmCheckTarget
              done

              runHook postCheck
            '';
            installPhase = ''
              runHook preInstall

              ${nodeModules.cleanupLinks} "$PWD"
              mkdir -p $out
              cp -r . $out
              ${nodeModules.createLinks} "$out"

              runHook postInstall
            '';
          });
        in
        final;
    }
  );
in
scope.overrideScope overrideScope
