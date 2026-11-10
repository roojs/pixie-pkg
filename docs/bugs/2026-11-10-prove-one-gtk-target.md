# Prove one GTK target from the published pins

**Status:** open  
**Started:** 2026-11-10

## Problem

`Knowles/gtk` `.gitlab-ci/pixie-gtk-release.sh` clones pixiewood-pkgs and drives the build itself. For one tag it does all of this:

- Adds a GTK target for that tag.
- Merges `release.pins` with the fontconfig row from `snapshot.pins`.
- Rewrites wrap revisions so they match the published pins. Pango's wrap says `1.90` and the pin says `1.58.2`. This GTK accepts Pango through 1.59, so the script points the wrap at the pin to stop prove compiling 1.90. That is a hack.
- Refuses the run when anything except GTK would be compiled.
- Runs prove, which downloads the other libraries and compiles GTK.
- Writes `gtk-arm-v31-<version>.pixie`.

That is package-manager work. The GTK repository should name the tag and call `pixie-pkg`.

## Proposal

The command is `pixie-pkg prove`. From the GTK checkout the tag job calls:

```bash
pixie-pkg prove --tag "$CI_COMMIT_TAG" --out pixie-out
```

The command adds that tag as a GTK target, uses the published pins, downloads every library before GTK, and compiles GTK. It refuses the run when anything except GTK would be compiled. It writes `gtk-arm-v31-<version>.pixie`, with the version read from `meson.build`.

The caller names the tag. It does not clone pixiewood-pkgs, merge pin files, or edit wraps. The command does not edit wraps either.

For every library before GTK, the command chooses a published package. It does not name those libraries. A release pin is used when its version is one this checkout accepts. The limits are the checkout's `dependency()` lines and `VERSION_MAX_ALLOWED` lines. A library with no release pin uses its snapshot pin. A library with no acceptable pin would be compiled, and the command stops.

Pango is one case of that choice. Its wrap stays `1.90`. The release pin `1.58.2` is inside the range this GTK declares, so that pin is the package. Fontconfig has no release pin, so its snapshot pin is the package. The tag job's rewrite of wraps goes away.
