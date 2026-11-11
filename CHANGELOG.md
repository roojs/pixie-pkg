# Changelog

All notable changes to pixie-pkg are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for git tags (`v0.1.0`, etc.).

Debian and RPM packaging notes are generated from this file
(see [Creating releases](docs/creating-releases.md)).

**AI agents:** Read that document before editing this file. Do not run
`scripts/release.sh`.

## [Unreleased]

## [0.3.1] - 2026-11-11

- The release attaches one Debian package and one RPM. The apt suites share the `.deb`. The RPM repositories share the `.rpm`.

## [0.3.0] - 2026-11-11

- A pin file can list a package from another project under that project's git URL. `--repo` chooses among copies of the same package and still installs a package that appears once.

## [0.2.0] - 2026-11-10

- The command, Debian package, and RPM are named pixie-pkg.
- prove compiles one package tag from the published pins.
- install, pull, fetch, and prove read pin lists from the pixiewood-pkgs GitHub Pages site.

## [0.1.0] - 2026-11-09

- First package of the pixie command.
- install, pull, and apply place Pixiewood libraries under /usr/lib/pixie.
