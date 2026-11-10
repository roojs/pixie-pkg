# pixie-pkg

`pixie-pkg` installs prebuilt Android libraries. Each library is a `.pixie` file. [pixiewood-pkgs](https://github.com/roojs/pixiewood-pkgs) builds those files and publishes the pin list. This repository installs them.

```bash
pixie-pkg install
pixie-pkg pull
pixie-pkg apply
```

`install` downloads one whole set and activates it. `pull` downloads a later set. It skips the download when `pulled` is under 24 hours old; `--force` downloads again. `apply` activates the user directory, then the system directory, when that `pulled` file is under 24 hours old.

A user run writes to `~/.local/lib/pixie`. Root, `--system`, and the Debian package use `/usr/lib/pixie`. `--prefix` changes that system prefix. It defaults to `/usr`.

| | Tools | Libraries | Download cache |
| --- | --- | --- | --- |
| User | `~/.local/share/pixie-pkg`, `~/.local/bin/pixie-pkg` | `~/.local/lib/pixie` | `~/.cache/pixie` |
| System | `/usr/share/pixie-pkg`, `/usr/bin/pixie-pkg` | `/usr/lib/pixie` | `/var/cache/pixie` |

`release` is the set from `release.pins`. `snapshot` is the set from `snapshot.pins` (`pixie-pkg install --snapshot`). Both Android ABIs unpack into the same directory. `PIXIEWOOD_PIXIE` is that directory after `apply`.

The `.pixie` files stay on the pixiewood-pkgs GitHub release. The pin lists are `https://roojs.github.io/pixiewood-pkgs/release.pins` and `https://roojs.github.io/pixiewood-pkgs/snapshot.pins`. `PIXIE_REPO` and `PIXIE_BRANCH` read those file names from another project's git branch.

## Install on this machine

```bash
sudo scripts/install-local.sh
```

That copies the command to `/usr/bin/pixie-pkg` and the helpers to `/usr/share/pixie-pkg`. Set `PREFIX` to put them somewhere else.

Then:

```bash
sudo pixie-pkg install          # /usr/lib/pixie/release
pixie-pkg install               # ~/.local/lib/pixie/release
```

## Debian, RPM, and GitHub releases

Tag `vX.Y.Z` builds packages and attaches them to that GitHub release. This is the same container layout as [OLLMchat](https://github.com/roojs/OLLMchat).

Update [`CHANGELOG.md`](CHANGELOG.md), set the same version in `meson.build`, commit, then run [`scripts/release.sh`](scripts/release.sh). That is the release command. It checks the notes, the versions, and a clean tree, then tags and pushes. The tag push runs **Release**, which builds the `.deb` and `.rpm` packages. See [Creating releases](docs/creating-releases.md).

Debian: Plucky is `+plucky`, Questing is `+questing`, Trixie is `+trixie`, and Resolute has no suffix. RPM: Fedora 44 keeps its dist tag, and openSUSE Tumbleweed has none. `Release - Debian`, `Release - Fedora`, and `Release - openSUSE` build the same files without publishing.

Prefer the [roojs package repositories](https://roojs.github.io/repos/). The GitHub release is the matching file set.

## Use the libraries

```bash
export PIXIEWOOD_PIXIE="$(pixie-pkg apply)"
export PIXIEWOOD_REAL_MESON="$(command -v meson)"
pixiewood prepare \
  --sdk "$ANDROID_SDK_ROOT" \
  --meson /usr/share/pixie-pkg/meson-wrapper.sh \
  android/app.xml
/usr/share/pixie-pkg/stage-runtime.sh \
  "$PIXIEWOOD_PIXIE" \
  /path/to/app/.pixiewood/root
```

`pixie-pkg fetch --dest DIR` unpacks one set into a directory you name. That is the old `scripts/pixie.sh latest` command, without cloning pixiewood-pkgs.

Details: [what a pixie file is](docs/pixie-file.md), [using the libraries](docs/using-pixie-libraries.md), [how a project publishes](docs/sharing-your-library.md), [what GNOME Build Metadata would change](docs/gnome-build-meta.md).

## What stays in pixiewood-pkgs

Wraps, cross files, and the scripts that produce `.pixie` files stay in pixiewood-pkgs. That repository publishes the pin lists on GitHub Pages and the `.pixie` files as GitHub release assets. See [what pixiewood-pkgs keeps](docs/pixiewood-pkgs.md) before deleting anything there.

## Tests

```bash
bash tests/test-pixie-tree.sh
bash tests/test-meson-wrapper.sh
bash tests/test-pixie.sh
bash tests/test-install-layout.sh
bash tests/test-versions.sh
bash tests/test-release-info.sh
```

## Artificial intelligence usage

This project was developed with the assistance of artificial intelligence.

- Design overview is by the author
- Almost all of the code was written by AI
- Review of that code was light
