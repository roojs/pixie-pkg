# One noarch package. Same spec on Fedora and openSUSE.
# Fedora CI keeps the dist tag. openSUSE CI clears it.
#
# Build with:
#   scripts/ci/build-rpm.sh

Name: pixie-pkg
Version: %{pixie_version}
Release: 1%{?dist}
Summary: Package manager for pixie libraries
License: MIT
URL: https://github.com/roojs/pixie-pkg
Source0: pixie-pkg-%{version}.tar.gz
BuildArch: noarch

BuildRequires: meson
%if 0%{?fedora}
BuildRequires: ninja-build
%else
BuildRequires: ninja
%endif

Requires: bash
Requires: ca-certificates
Requires: curl
Requires: jq
Requires: tar
Requires: xz

%description
pixie-pkg installs the prebuilt Android libraries published by pixiewood-pkgs.
A system install keeps them in /usr/lib/pixie. A user install keeps them
in ~/.local/lib/pixie.

%prep
%setup -q

%build
meson setup build --prefix=%{_prefix}
ninja -C build

%install
DESTDIR=%{buildroot} meson install -C build

%files
%license LICENSE
%doc README.md
%{_bindir}/pixie-pkg
%{_datadir}/pixie-pkg

%changelog
* Tue Nov 10 2026 Alan Knowles <alan@roojs.com> - 0.2.0-1
- The command, Debian package, and RPM are named pixie-pkg.
- prove compiles one package tag from the published pins.
- install, pull, fetch, and prove read pin lists from the pixiewood-pkgs GitHub Pages site.

* Mon Nov 09 2026 Alan Knowles <alan@roojs.com> - 0.1.0-1
- First package of the pixie command.
- install, pull, and apply place Pixiewood libraries under /usr/lib/pixie.
