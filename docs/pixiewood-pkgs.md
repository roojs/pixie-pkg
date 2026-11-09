# What pixiewood-pkgs keeps

pixiewood-pkgs builds the `.pixie` files and publishes them. This repository installs those files. When pixiewood-pkgs is trimmed, it should keep the build and the releases, and drop the install command that now lives here.

## Keep

These are how a `.pixie` file gets built and published:

- `packages/` — Meson wraps and `packagefiles/`, including the generated OpenSSL tree
- `cross/`, `android-distro.conf`, `build-order.txt`
- `release.pins` and `snapshot.pins`
- The build and publish scripts: `build-pixie.sh`, `build-changed.sh`, `prove-package.sh`, `publish-package.sh`, `publish-index.sh`, `current-pins.sh`, `pins.sh`, `upstream-index.sh`, `obtain-package.sh`, `packaged-deps.sh`, `checkout-cache.sh`, `list-package-cache.sh`, `install-sdk.sh`, `ci-host-setup.sh`, `gtk-part.sh`, `gtk-target.sh`, `place-upstream-plans.sh`
- `pixie-tree.sh` and `pixie-common.sh`, because packing a file still runs there
- `meson.build` and `sysroot/probe.c`
- `.github/workflows/prove-package.yml` and `monitor-upstreams.yml`
- The tests that drive the build

Wraps stay in pixiewood-pkgs. They are the recipes that build compiles. This package never reads a wrap.

## Drop once applications call `pixie-pkg`

- `scripts/pixie.sh` — `pixie-pkg fetch` and `pixie-pkg install` replace it
- `scripts/activate-pixie.sh`, `scripts/stage-runtime.sh`, `scripts/meson-wrapper.sh`, `scripts/verify-pixie.sh` — installed with this package under `share/pixie-pkg`
- The end-user docs (`docs/using-pixie-libraries.md`, `docs/local-install-plan.md`, `docs/pixie-file.md`, `docs/sharing-your-library.md`) — the current copies are in this repository
- Tests that only pack, activate, or stage a tree, once pixiewood-pkgs no longer needs them

pixiewood-pkgs can keep its own copy of a helper until the build calls the installed `pixie-pkg` command. Deleting `pixie-tree.sh` there before that would stop it packing `.pixie` files.
