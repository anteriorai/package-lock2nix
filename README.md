# package-lock2nix: build package-lock.json projects in Nix

This is Anterior’s build system for projects based on package-lock.json.  Unlike e.g. npm2nix, this builder fully parses the package-lock.json at Nix eval time, requiring no separate Nix codegen step.  It makes heavy use of symlinks which is not always compatible with every dependency: we are OK with this trade-off at Anterior, but it’s not for everyone.

The big win: **no separate Nix codegen step.** When you update your package-lock.json, changes are automatically picked up.

## No warranty. Really, seriously!

This project is _actually_ provided as-is: the license text truly applies.  We release this source code in the hopes that it will be useful to anyone, but we reserve the right to:

- change the API at any time
- introduce backwards incompatible changes
- force-push commits which change git history
- never fix bugs which don’t affect us, even if we know about them
- not accept pull requests
- introduce changes which are only useful for us, Anterior.

Seriously though!  Please be warned this is just a source code release under the AGPLv3.  It is not a commitment to becoming long time maintainers of this project for public consumption.  We want to give back code, and we really do hope this is useful to you, but we’re too busy to be maintainers at the moment.  The license says it very well:

> This program is distributed in the hope that it will be useful,
> but WITHOUT ANY WARRANTY; without even the implied warranty of
> MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
> GNU Affero General Public License for more details.

We hope by being super clear about this, here, in the readme, that nobody will be upset down the line if we ignore your PRs, or disable github issues.

That said: happy hacking!

Thank you.
