# Sharing your library

A project that shares Android libraries publishes a pin file. `pixie-pkg` reads that file and downloads each `.pixie` file named there. For the GTK stack the lists are `https://roojs.github.io/pixiewood-pkgs/release.pins` and `https://roojs.github.io/pixiewood-pkgs/snapshot.pins`. `https://roojs.github.io/pixiewood-pkgs/` says what those two files are.

Release or snapshot is the pin file. `release.pins` is the release list. `snapshot.pins` is optional.

```json
{
  "packages": [
    {
      "abi": "arm64-v8a",
      "repo": "https://gitlab.gnome.org/GNOME/gtk.git",
      "name": "openssl",
      "track": "openssl-3.0.8.tar.gz",
      "resolved": "6c13d2bf...",
      "inputs": "<inputs>",
      "url": "https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108/openssl-arm-v31-3.0.8.pixie"
    }
  ]
}
```

`snapshot.pins` uses the same objects. The file name ends in `-snapshot.pixie`.

| Field | Meaning |
| --- | --- |
| `abi` | Android ABI directory, `arm64-v8a` or `x86_64`. The file name says `arm` or `x86` |
| `repo` | Full git URL of the GTK checkout, `https://gitlab.gnome.org/GNOME/gtk.git` |
| `name` | Package name |
| `track` | Upstream version, tag, branch, or commit that was built |
| `resolved` | Commit or tarball identity that was built |
| `inputs` | Hash of the recipe that produced the file |
| `url` | Download URL of the `.pixie` file |

## Publish

1. Publish `release.pins` where applications read it. The GTK stack uses the Pages URLs above. Add `snapshot.pins` when you publish snapshots.
2. Upload one `.pixie` per library. An official release uses its version, such as `3.0.8`. Anything else uses `snapshot`. The file name is `{name}-arm-v{api}-{version}.pixie` or `{name}-x86-v{api}-{version}.pixie`.
3. The package object in the pin file matches the uploaded file. Each pin's `url` is that download.
4. The GitHub release holds the `.pixie` files.

A line's URL can point at a `.pixie` file published by another repository. `pixie-pkg install --repo URL` selects the GTK checkout when a pin file lists more than one. The Android IME branch and webkitgtk-android are separate projects, with their own branches and their own pin files.

`PIXIE_REPO` and `PIXIE_BRANCH` read `release.pins` or `snapshot.pins` from another project's git branch.
