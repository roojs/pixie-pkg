# Using pixie libraries

Install the `pixie` command from this repository, then put one set on the machine:

```bash
pixie install
pixie install --snapshot
```

`install` reads `release.pins` on `main` of `roojs/pixiewood-pkgs`. `--snapshot` reads `snapshot.pins`. Each package object names one `.pixie` file. Both ABIs unpack into one directory. See [What a pixie file is](pixie-file.md).

A user run writes `~/.local/lib/pixie`. Root and `--system` write `/usr/lib/pixie`.

A later set is an explicit pull. A build does not pull on its own.

```bash
pixie pull
pixie pull --force
pixie apply
```

`apply` prints the directory and sets it up for a build. `PIXIEWOOD_PIXIE` is that path. `pulled` in the directory is the UTC time the set finished arriving. `apply` stops when that time is missing or older than 24 hours.

To unpack into a directory you name, instead of the library directory:

```bash
pixie fetch --dest "$HOME/pixiewood"
pixie fetch --snapshot --dest "$HOME/pixiewood"
```

## From Pixiewood

Leave the Pixiewood checkout as it is. `prepare` already accepts another Meson program. Point that at the installed wrapper, and point the wrapper at the directory from `apply`:

```bash
export PIXIEWOOD_PIXIE="$(pixie apply)"
export PIXIEWOOD_REAL_MESON="$(command -v meson)"
pixiewood prepare \
  --sdk "$ANDROID_SDK_ROOT" \
  --meson /usr/share/pixie/meson-wrapper.sh \
  android/app.xml
```

The wrapper adds `share/pixiewood/pixie.cross` to `meson setup`. Pass that same `--cross-file` again on every later reconfigure. `pixie.cross` follows arm64-v8a when that ABI is present. `pixie apply --abi x86_64` writes the cross file for the other ABI. `share/pixiewood/pixie-arm64-v8a.cross` and `share/pixiewood/pixie-x86_64.cross` are both written when both ABIs were installed.

Set the Java glue on the manifest:

```xml
<build
  target="app"
  java-sources="/usr/lib/pixie/release/share/pixiewood/gtk-android-java">
```

Copy the libraries and GSettings schemas into the app tree before Gradle, and before Pixiewood runs `glib-compile-schemas`:

```bash
/usr/share/pixie/stage-runtime.sh \
  "$PIXIEWOOD_PIXIE" \
  /path/to/app/.pixiewood/root
```

Libraries named in `share/pixiewood/MANIFEST.json` are already built. Remove `subprojects/<name>.wrap` for those names so Meson keeps the pixie copy. Anything absent from that list is still built from a wrap. Icons, the CA bundle, shared-mime-info, and the application's own Java classes stay with the app.

A user install has the same scripts under `~/.local/share/pixie`.
