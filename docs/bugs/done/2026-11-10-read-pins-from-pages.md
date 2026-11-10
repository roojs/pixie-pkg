# Read the pin lists from the project page

**Status:** closed  
**Started:** 2026-11-10  
**Closed:** 2026-11-10

## Problem

pixiewood-pkgs publishes the pin lists on its GitHub Pages site. It does not commit them.

- `https://roojs.github.io/pixiewood-pkgs/release.pins` is the released set.
- `https://roojs.github.io/pixiewood-pkgs/snapshot.pins` is the snapshot set.
- `https://roojs.github.io/pixiewood-pkgs/` says what those two files are.

The `.pixie` files stay on the GitHub release. Each pin's `url` is that download.

`install`, `pull`, and `fetch` still build `https://raw.githubusercontent.com/roojs/pixiewood-pkgs/main/release.pins` from `PIXIE_REPO` and `PIXIE_BRANCH`. That is `main`. `main` is no longer the published list.

`prove` clones pixiewood-pkgs and reads `release.pins` and `snapshot.pins` out of that clone. The clone is still how prove gets the build order, the wraps, and `scripts/build-pixie.sh`. The pin files in the clone are the last copy committed on `main`, not the published lists.

## Change

`pins_source()` downloads the two Pages URLs when the caller does not pass `--pins`. `--pins` still names a local file.

`prove` downloads those same two URLs. It uses them for the choice it already makes: a release pin when the version is one this checkout accepts, otherwise the snapshot pin.

`PIXIE_REPO` and `PIXIE_BRANCH` remain the way another project publishes pin files from its own git branch.

These sentences say the lists are read from `main`, or that a publisher commits them. They follow the Pages URLs:

- `README.md`
- `docs/using-pixie-libraries.md`
- `docs/sharing-your-library.md`
- `docs/pixiewood-pkgs.md`
