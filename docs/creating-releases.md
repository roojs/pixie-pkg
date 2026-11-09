# Creating releases

Users install pixie-pkg from the **[roojs package repositories](https://roojs.github.io/repos/)** (`apt` / `dnf` / `zypper`). A tag push also publishes one GitHub Release with the matching `.deb` and `.rpm` files.

The [Release](../.github/workflows/release.yml) workflow (`name: Release`) runs when:

- a tag matching `v*` is pushed (run **`./scripts/release.sh`** — humans only; `v*-packages` is ignored), or
- **Release** is started manually from the GitHub Actions UI (**workflow_dispatch**).

To test **one** package family without waiting on the others, run the matching
`Release - …` workflow on your branch (same jobs Release uses; no publish):

| Actions name | File | Command |
|--------------|------|---------|
| **Release - Debian** | [`release-debian.yml`](../.github/workflows/release-debian.yml) | `gh workflow run release-debian.yml --ref <branch>` |
| **Release - Fedora** | [`release-fedora.yml`](../.github/workflows/release-fedora.yml) | `gh workflow run release-fedora.yml --ref <branch>` |
| **Release - openSUSE** | [`release-opensuse.yml`](../.github/workflows/release-opensuse.yml) | `gh workflow run release-opensuse.yml --ref <branch>` |

Ignore anything named **X - …**. Those are the package-build jobs Release calls.

CI then:

1. Builds **Debian** packages. Plucky is `+plucky`, Questing is `+questing`, Trixie is `+trixie`, and Resolute has no suffix.
2. Builds **RPMs** on **Fedora 44** (dist tag kept) and **openSUSE Tumbleweed** (no dist tag) from the same spec.
3. On a tag push, publishes one GitHub Release with those files. The notes come from [`CHANGELOG.md`](../CHANGELOG.md).

Manual **workflow_dispatch** runs upload artifacts on that workflow run. They do not publish a GitHub Release and do not finalize the changelog.

## Changelog

Release notes live in [`CHANGELOG.md`](../CHANGELOG.md). `debian/changelog` and the RPM `%changelog` are **generated** from it. Do not edit those by hand.

Check the latest `v*` tag before editing. A versioned heading (for example `## [0.2.0] - Unreleased` or a dated `## [0.1.0] - 2026-11-09`) is that release’s notes. Do not append to it after the version is chosen or tagged. While developing, add bullets only under **`## [Unreleased]`**. When the release is ready, rename that heading to the version, for example `## [0.2.0] - Unreleased`, and set the same version in `meson.build`.

`scripts/release.sh` is the release command. It refuses to tag when `meson.build` disagrees with `CHANGELOG.md`. When `debian/changelog` or the RPM `%changelog` disagree, it rewrites them from `CHANGELOG.md` and stops so you can commit that and run it again. You can regenerate those files on their own with:

```bash
./scripts/release/sync-debian-changelog.sh
```

**Tag push (via `scripts/release.sh`):**

1. CI reads the versioned heading, checks it matches the tag and `meson.build`, and copies the notes into Debian and RPM packaging **in the CI workspace**.
2. GitHub Release notes come from that same section (`scripts/release/render-release-notes.sh`).
3. If the workflow **fails**, `CHANGELOG.md` on `main` is unchanged.
4. If it **succeeds**, CI runs **`finalize-changelog.sh`**, stamps the date on the version, inserts a fresh `[Unreleased]` heading, regenerates `debian/changelog` and the RPM `%changelog`, and commits that to `main`.

Agents must not run `scripts/release.sh` (it refuses `CURSOR_AGENT=1` and must not be worked around). Agents must not modify `CHANGELOG.md` without reading this section.

## Making a release

1. **Finish the release on `main`.** Commit everything that should ship.

2. **Update `CHANGELOG.md`.** Put the notes under `## [0.2.0] - Unreleased` (version in the heading). Set `version:` in `meson.build` to the same number. Commit.

3. **Run the human-only release script:**

   ```bash
   ./scripts/release.sh
   ```

   Run it on `main`. It checks a clean tree, refuses empty notes, and checks the version in `meson.build`, `debian/changelog`, and the RPM spec. When those packaging changelogs are stale it rewrites them and stops; commit that and run the script again. When the tree is clean it creates an annotated `v0.2.0` tag and pushes `main` plus the tag. Do not tag by hand.

   If CI failed for that version, commit the fix on `main` then retag:

   ```bash
   ./scripts/release.sh --retry
   ```

   That deletes the local and origin version tag (and a matching `v*-packages` tag, if one was pushed), then tags HEAD and pushes again.

4. **Watch CI.** Open **Actions → Release** on GitHub and wait for Debian, Fedora, openSUSE, and Publish to finish. Publish tags the GitHub Release and attaches the packages. That is the run that fills the [roojs package repositories](https://roojs.github.io/repos/) after the repos ingest picks up the assets.

The version tag (`v0.1.0`) carries:

| File | Platform |
|------|----------|
| `*+trixie_all.deb` | Debian 13 trixie |
| `*+plucky_all.deb` | Ubuntu 25.04 |
| `*+questing_all.deb` | Ubuntu 25.10 |
| `pixie-pkg_*.deb` without a suite `+` label | Ubuntu 26.04 resolute |
| `pixie-pkg-*.fc44.*.rpm` | Fedora 44 |
| `pixie-pkg-*.rpm` without `.fc` | openSUSE Tumbleweed |
