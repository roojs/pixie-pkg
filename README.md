# pixie

`pixie` installs prebuilt Android libraries. Each library is a `.pixie` file. [pixiewood-pkgs](https://github.com/roojs/pixiewood-pkgs) builds those files and publishes the pin list. This repository installs them.

```bash
pixie install
pixie pull
pixie apply
```

`install` downloads one whole set and activates it. `pull` downloads a later set. It skips the download when `pulled` is under 24 hours old; `--force` downloads again. `apply` activates the user directory, then the system directory, when that `pulled` file is under 24 hours old.

A user run writes to `~/.local/lib/pixie`. Root, `--system`, and the Debian package use `/usr/lib/pixie`. `--prefix` changes that system prefix. It defaults to `/usr`.

| | Tools | Libraries | Download cache |
| --- | --- | --- | --- |
| User | `~/.local/share/pixie`, `~/.local/bin/pixie` | `~/.local/lib/pixie` | `~/.cache/pixie` |
| System | `/usr/share/pixie`, `/usr/bin/pixie` | `/usr/lib/pixie` | `/var/cache/pixie` |

`release` is the set from `release.pins`. `snapshot` is the set from `snapshot.pins` (`pixie install --snapshot`). Both Android ABIs unpack into the same directory. `PIXIEWOOD_PIXIE` is that directory after `apply`.

The pin files and the `.pixie` assets stay on pixiewood-pkgs. `pixie` reads `main` of `roojs/pixiewood-pkgs` unless `PIXIE_REPO` or `PIXIE_BRANCH` is set.

## Install on this machine

```bash
sudo scripts/install-local.sh
```

That copies the command to `/usr/bin/pixie` and the helpers to `/usr/share/pixie`. Set `PREFIX` to put them somewhere else.

Then:

```bash
sudo pixie install          # /usr/lib/pixie/release
pixie install               # ~/.local/lib/pixie/release
```

## Debian, RPM, and GitHub releases

Tag `vX.Y.Z` builds packages and attaches them to that GitHub release. This is the same container layout as [OLLMchat](https://github.com/roojs/OLLMchat).

Debian: Plucky is `+plucky`, Questing is `+questing`, Trixie is `+trixie`, and Resolute has no suffix. RPM: Fedora 44 keeps its dist tag, and openSUSE Tumbleweed has none. `Release - Debian`, `Release - Fedora`, and `Release - openSUSE` build the same files without publishing.

Prefer the [roojs package repositories](https://roojs.github.io/repos/). The GitHub release is the matching file set.

The package version is `0.1.0` in `meson.build` and `debian/changelog`. A tag build refuses to run when those disagree with the tag.

## Use the libraries

```bash
export PIXIEWOOD_PIXIE="$(pixie apply)"
export PIXIEWOOD_REAL_MESON="$(command -v meson)"
pixiewood prepare \
  --sdk "$ANDROID_SDK_ROOT" \
  --meson /usr/share/pixie/meson-wrapper.sh \
  android/app.xml
/usr/share/pixie/stage-runtime.sh \
  "$PIXIEWOOD_PIXIE" \
  /path/to/app/.pixiewood/root
```

`pixie fetch --dest DIR` unpacks one set into a directory you name. That is the old `scripts/pixie.sh latest` command, without cloning pixiewood-pkgs.

Details: [what a pixie file is](docs/pixie-file.md), [using the libraries](docs/using-pixie-libraries.md), [how a project publishes](docs/sharing-your-library.md).

## What stays in pixiewood-pkgs

Wraps, cross files, and the scripts that produce `.pixie` files stay in pixiewood-pkgs. That repository publishes `release.pins`, `snapshot.pins`, and the GitHub release assets. See [what pixiewood-pkgs keeps](docs/pixiewood-pkgs.md) before deleting anything there.

## Tests

```bash
bash tests/test-pixie-tree.sh
bash tests/test-meson-wrapper.sh
bash tests/test-pixie.sh
bash tests/test-install-layout.sh
bash tests/test-versions.sh
```

## Artificial intelligence usage

This project was developed with the assistance of artificial intelligence.

- Design overview is by the author
- Almost all of the code was written by AI
- Review of that code was light
