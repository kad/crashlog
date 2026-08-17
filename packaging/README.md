# Distribution Packaging

This directory contains the material needed to build native packages of the Lightweight Crash Log
Framework. The Debian packaging lives in the [`debian`](../debian) directory at the root of the
repository, where `dpkg-buildpackage` expects it; everything else is here.

## Packages

Every distribution produces the same four packages, named according to its own conventions:

| Contents | Debian / Ubuntu | Fedora / RHEL | openSUSE |
| --- | --- | --- | --- |
| `iclg` command line tool, manual pages, shell completions | `intel-crashlog` | `intel-crashlog` | `intel-crashlog` |
| Shared library `libintel_crashlog.so.1` | `libintel-crashlog1` | `intel-crashlog-libs` | `libintel_crashlog1` |
| C and C++ headers, pkg-config file, linker symbolic link | `libintel-crashlog-dev` | `intel-crashlog-devel` | `intel-crashlog-devel` |
| `iclg.efi` UEFI application | `intel-crashlog-efi` | `intel-crashlog-efi` | `intel-crashlog-efi` |

The Fedora and the openSUSE packages come from the same spec file, which branches on
`0%{?suse_version}` where the two distributions differ; see the section on the distribution
guidelines below. The name of the shared library package is one of those differences: openSUSE
derives it from the library file name, so it keeps the underscore of the SONAME.

The library keeps the SONAME `libintel_crashlog.so.1`, derived by [`lib/build.rs`](../lib/build.rs)
from the major version of the crate. The binary package name follows the SONAME, so a future
incompatible release will be co-installable with this one.

The manual pages and the shell completion scripts are not maintained by hand: they are generated at
build time from the clap command line definition by the hidden `iclg generate-assets` sub-command,
which comes from the `generate-assets` feature of the `intel_crashlog_app` crate. They therefore
cannot drift from the actual interface.

## Vendored dependencies

The dependencies are bundled: the sources are vendored into a `vendor` directory and the package
build resolves everything from there, with `CARGO_NET_OFFLINE=true`, and never reaches the network.

Most of the crates are available in both archives, as `librust-*-dev` on Debian and Ubuntu and as
`rust-*` on Fedora, so building against them is a legitimate alternative for the library and the
command line tool; it is a larger change than it looks, though, because the versions in the archive
move independently of the lock files and the build would have to stop using `--locked`. For the UEFI
application it is not an option at all: the `uefi` crates and their dependencies are not packaged,
and neither distribution builds Rust code for the `x86_64-unknown-uefi` target. Vendoring keeps the
three crates building the same way, and both distributions accept it for applications as long as
what is bundled is declared, which is what the `Provides: bundled(crate(...))` entries of the spec,
the `vendor/*` stanzas of `debian/copyright` and the `XS-Vendored-Sources-Rust` field of
`debian/control` do. On the Ubuntu side vendoring is not merely accepted: the Main Inclusion Review
rules for Rust require code in `main` to vendor its dependencies rather than use the individual
crate packages.

`cargo vendor` has no way of restricting itself to the platforms that are built, so the tree also
carries the Windows halves of `jiff` and of the `clap` colour support. Ubuntu suggests removing such
dependencies from the vendored sources; `vendor.sh --prune-windows` does that, but it is off by
default, because a crate Cargo still resolves and can no longer find is a build failure nothing in
this repository would catch. Enabling it means verifying an offline `--locked` build of all three
crates and regenerating `XS-Vendored-Sources-Rust`.

The vendoring is done once by the package maintainer, not during the package build:

```console
$ ./packaging/create-tarballs.sh
```

This exports the sources from Git, vendors the dependencies and writes four tarballs into the parent
directory: `intel-crashlog-<version>.tar.xz` and `intel-crashlog-<version>-vendor.tar.xz` for the
RPM build, plus `intel-crashlog_<version>.orig.tar.xz` and
`intel-crashlog_<version>.orig-vendor.tar.xz`, which are the names the Debian source package tooling
expects. The vendored sources are an additional component of the Debian upstream tarball, so
`dpkg-source` unpacks them into `vendor/` on its own.

Both builds resolve the dependencies with `--locked`, so the lock files that are exported into the
tarball have to be the ones describing the vendored sources. Vendoring refreshes them as a side
effect, and `create-tarballs.sh` stops if that leaves the working tree out of sync with the revision
it exports: commit the refreshed lock files and run it again.

The dependencies are vendored into `vendor/` in the working tree, which is where both builds resolve
them from, so a package built from the tree is as offline as one built from the source package.

When the dependency tree changes, refresh the licensing information that both distributions require
for bundled code:

```console
$ ./packaging/vendor-licenses.sh              # license expression per crate, for review
$ ./packaging/vendor-licenses.sh -f rpm       # Provides: bundled(crate(...)) lines, for the spec
$ ./packaging/vendor-licenses.sh -f dep5      # Files stanzas covering vendor/*, for debian/copyright
$ ./packaging/vendor-licenses.sh -f manifest  # the same list without cargo-rpm-macros, for the spec
$ make -f debian/rules vendored-sources       # XS-Vendored-Sources-Rust, for debian/control
```

The last one is `dh-cargo-vendored-sources` from the Ubuntu build of `dh-cargo`. `debian/rules` also
runs it during `dh_auto_configure` when it is installed, so a build there fails until the field
matches the vendored tree, and prints the value it should have.

The first two formats describe what is linked into the binaries, grouped by crate of this
repository, because each of them ends up in a different package. They are filtered by target
platform, so the `windows` and `uefi` crates only show up where they apply, and build time
dependencies such as `cbindgen` and test only ones such as `tempfile` are left out. The `Provides`
blocks of the spec file are delimited by `# BUNDLED-PROVIDES-BEGIN` comments and are meant to be
replaced wholesale.

The `dep5` format is deliberately different: it walks `vendor/` and covers every directory in it,
including the crates that are only compiled at build time or that apply to another platform, because
`debian/copyright` has to account for the source package as it is shipped rather than for what ends
up in the binaries. Reading the tree directly also gets the directory names right where `cargo
vendor` had to disambiguate two versions of the same crate, as `vendor/memchr-2.8.1`. It needs
`vendor/` to be present, and Python 3.11 or later for `tomllib`.

The `manifest` format also walks `vendor/`, and produces the plain list of crate, version and
license expression that `%cargo_license_summary` and `LICENSE.dependencies` provide on Fedora. It
exists for the distributions that have no `cargo-rpm-macros`, which is why the spec calls it on the
openSUSE path, and it parses the few manifest fields it needs itself rather than with `tomllib`, so
that it also works in a build root whose Python predates it.

## Building the Debian package

```console
$ ./packaging/create-tarballs.sh
$ dpkg-buildpackage -us -uc
```

## Building the RPM package

```console
$ ./packaging/create-tarballs.sh
$ cp ../intel-crashlog-*.tar.xz ~/rpmbuild/SOURCES/
$ rpmbuild -ba packaging/rpm/intel-crashlog.spec
```

Or, to build in a clean chroot:

```console
$ rpmbuild -bs packaging/rpm/intel-crashlog.spec
$ mock --rebuild ~/rpmbuild/SRPMS/intel-crashlog-*.src.rpm
```

The same commands build the packages on openSUSE Tumbleweed, with one addition: it only splits the
debugging information out into `-debuginfo` packages when the build asks for them, so add `--define
"_build_create_debug 1"`. Without it the packages keep the debugging information that the spec
deliberately does not strip, and `rpmlint` reports unstripped binaries. Leap is too old for this
spec, which needs rpm 4.17 for `%bcond_with` and Rust 1.85 for edition 2024.

## Building in containers

[`packaging/docker`](docker) builds all of it in containers, so nothing has to be installed on the
machine that runs it and every build starts from a clean root:

```console
$ ./packaging/docker/build.sh                     # ubuntu, fedora and opensuse
$ ./packaging/docker/build.sh -o /tmp/pkgs fedora # one distribution, chosen output directory
$ ./packaging/docker/build.sh --efi -r v1.1.0     # a tag, with the UEFI application
```

The flow mirrors what a distribution build service does. One container exports the requested
revision, vendors the dependencies and produces the source packages; that is the only step with
network access. Each distribution container then builds from those source packages — a `.dsc`
unpacked with `dpkg-source` on Ubuntu, a source RPM rebuilt with `rpmbuild --rebuild` on Fedora and
openSUSE — with the network switched off, which is what proves that the vendored sources are
complete, and runs `lintian` or `rpmlint` over the result. The output directory ends up with a
`source` subdirectory and one per distribution, each holding the packages and the linter report. A
linter that reports problems does not stop the other builds: the packages are kept and the script
exits non-zero at the end with a summary of what failed.

Because the containers build a source package exported from Git, the packaging has to be committed
before it can be built; `build.sh` says so instead of starting. `-r` selects the revision, and
`--skip-source` reuses the source packages already in the output directory, which saves the
vendoring step while iterating on one distribution. Set `DOCKER=podman` to use Podman. The pieces
are:

| File | Role |
| --- | --- |
| [`build.sh`](docker/build.sh) | Host driver: builds the images, runs the containers, collects the results |
| [`Dockerfile.source`](docker/Dockerfile.source) + [`make-source.sh`](docker/make-source.sh) | Exports the revision, vendors, writes the tarballs and the `.dsc` |
| [`Dockerfile.ubuntu`](docker/Dockerfile.ubuntu) + [`build-deb.sh`](docker/build-deb.sh) | `dpkg-buildpackage` on `ubuntu:latest`, then `lintian` |
| [`Dockerfile.fedora`](docker/Dockerfile.fedora) + [`build-rpm.sh`](docker/build-rpm.sh) | `rpmbuild` on `fedora:latest`, then `rpmlint` |
| [`Dockerfile.opensuse`](docker/Dockerfile.opensuse) + [`build-rpm.sh`](docker/build-rpm.sh) | The same on `opensuse/tumbleweed:latest` |

The build dependencies are installed when the image is built rather than when the package is built,
so that the package build itself needs no network: `mk-build-deps` reads `debian/control`, `dnf
builddep --spec` reads the spec, and on openSUSE, which has no equivalent, the `BuildRequires` are
read out of the spec with `rpmspec` and handed to `zypper`. Both lists therefore come from the
revision being built, and an image is rebuilt when they change.

Two things are worth knowing before the first run. `--efi` is the exception to the offline rule: the
UEFI toolchain is downloaded by `rustup` during the build, so those containers are given network
access and their packages are not reproducible from the source package alone. And the Ubuntu build
fails until `XS-Vendored-Sources-Rust` in `debian/control` matches the vendored tree exactly —
`dh-cargo-vendored-sources` checks it and prints the value it should have, so the fix is to copy
that into `debian/control` and commit it.

## The UEFI application

The UEFI application is not built by default, because the `x86_64-unknown-uefi` target is not
covered by the Rust toolchain that either distribution ships: building it needs a
[rustup](https://rustup.rs/) managed toolchain that provides the standard library for that target,
which in turn needs network access. Both builds install that toolchain under their own build
directory, by setting `RUSTUP_HOME`, and invoke it through `rustup run`, since the `cargo` on `PATH`
is the one from the distribution. It is therefore unsuitable for an official distribution build and
has to be requested explicitly:

```console
$ dpkg-buildpackage -us -uc -P pkg.intel-crashlog.efi
$ rpmbuild -ba --with efi packaging/rpm/intel-crashlog.spec
```

The resulting binary is installed in `/usr/lib/intel-crashlog/efi/iclg.efi` on Debian and
`/usr/libexec/intel-crashlog/efi/iclg.efi` on Fedora. It is not run on the installed system: copy it
to a FAT32 partition and start it from the UEFI shell, as described in
[`efi/README.md`](../efi/README.md).

## Relationship to the distribution guidelines

Both distributions package Rust libraries individually, as `librust-*-dev` on Debian and as `rust-*`
on Fedora, and Debian and Fedora both expect applications to be built against those packages. Both
also document the alternative for applications, which is what this packaging follows: the
dependencies are bundled as vendored sources, the build is offline, and every package that contains
compiled Rust code declares what it bundles. Ubuntu is the exception in the other direction — its
Main Inclusion Review rules for Rust *require* code in `main` to vendor — so this shape is the one
Ubuntu asks for outright. See the section on the vendored dependencies above; the parts that would
have to change for an archive that insists on the individually packaged crates are listed at the end
of this section.

On the Fedora side this means the spec follows the vendored variant of the Rust packaging
guidelines. `cargo-rpm-macros` is used for the licensing artefacts the guidelines require —
`%cargo_license_summary` in the build log, `LICENSE.dependencies` and `cargo-vendor.txt` shipped as
`%license` in every package that contains bundled code — and each of those packages carries the
matching `Provides: bundled(crate(...))` entries. The `License` tag is the SPDX expression covering
the bundled crates as well as the sources of this repository. The build does not use `%cargo_prep`,
`%cargo_build`, `%cargo_install` or `%cargo_generate_buildrequires`: those macros describe a single
crate that is built and installed by Cargo, whereas this repository has three independent crates,
one of which is a `cdylib` with a SONAME and one of which is built for `x86_64-unknown-uefi`.
Everything the macros would set up — the source replacement stanza, the offline mode, `RUSTFLAGS`
from `%{build_rustflags}`, and the profile overrides that keep the debugging information — is set
explicitly instead, and the spec says so at each point. If a package review prefers the crates to be
packaged individually, the `Provides` blocks and the vendoring can be dropped in favour of
`%cargo_generate_buildrequires`.

openSUSE builds from the same spec, and the differences between the two are handled by two kinds of
test on purpose. Whether the macros of `cargo-rpm-macros` exist is a property of the build
environment, so it is asked with `%{defined ...}` and each macro has a fallback definition:
`%{cargo_home}` and `%{build_rustflags}` get one, and the licensing block falls back to
`vendor-licenses.sh -f manifest`, which produces the same per-crate list that `%cargo_license` ships
and `%cargo_license_summary` prints. A build root that grows the macros later therefore starts using
them without an edit. Package naming and the `ldconfig` scriptlets, on the other hand, are
distribution policy rather than a capability, so they are keyed on `0%{?suse_version}`: the shared
library package is `libintel_crashlog1` under the openSUSE shared library policy, and it calls
`ldconfig` from `%post` and `%postun`, which on Fedora is unnecessary because rpm runs it from a
file trigger of `glibc`. Nothing else in the spec is conditional, and the four combinations of
distribution and `--with efi` were checked to expand without a leftover macro.

On the Debian side, `dh-cargo` and its `--buildsystem cargo` are not used for the same reason: they
build one crate against the crates in the archive. The parts of the Rust packaging conventions that
do apply are respected: `CARGO_HOME` and everything Cargo or rustup writes stay under `debian/`, the
build runs with `CARGO_NET_OFFLINE=true` and `--locked`, `RUSTFLAGS` carries the linker flags of the
distribution through `-Clink-arg`, and the vendored sources are described in `debian/copyright`.
`Static-Built-Using` is set on the three packages that contain compiled code, because the Rust
standard library from `libstd-rust-dev`, which is built from `src:rustc`, is linked statically into
`iclg`, into `libintel_crashlog.so.1` and into `iclg.efi`. `debian/rules` fills it in from
`dpkg-query`, which is what `dh-cargo` would otherwise provide as a substitution variable. The
bundled crates do not belong in that field: they are part of this source package rather than of
another one in the archive. They are declared in `XS-Vendored-Sources-Rust` instead, which
`dh-cargo-vendored-sources` checks against `vendor/` during `dh_auto_configure`. `dh-cargo` is in
`Build-Depends` only for that script; the Debian build of the package does not ship it yet, so the
check is skipped there.

Three further conventions are worth recording, because they are satisfied rather than worked around.
The Debian Rust policy puts all the binary targets of a crate into a single Debian binary package;
the split here is along different lines, since `libintel-crashlog1` holds a `cdylib` with a C ABI
and a SONAME rather than a Rust library, and `iclg.efi` comes from a separate crate built for a
separate target. Rust code in Ubuntu `main` that does TLS has to use the system OpenSSL rather than
`rustls`; nothing in the dependency tree does TLS at all. And crates that pin a toolchain through
`rust-toolchain.toml` are normally kept out of the archive; `efi/rust-toolchain.toml` only requests
the `x86_64-unknown-uefi` target and pins neither a channel nor a version, so a stable `rustc`
builds it and `rustup` is needed only for the standard library of that target. All three should be
re-checked when the dependency tree changes.

Two things about the vendored tree need attention before an upload to either archive: the blanket
`Files: vendor/*` stanzas in `debian/copyright` should be replaced with the per-crate stanzas that
`vendor-licenses.sh -f dep5` generates, and the `License` tag of the spec has to be checked against
what `%cargo_license_summary` reports for the release being packaged. If a reviewer asks for the
crates from the archive to be used instead, the pieces to remove are the vendoring in
`create-tarballs.sh` and the vendor component of the tarball, the `Provides: bundled(crate(...))`
blocks and the `vendor/*` stanzas, and `--locked` from both builds; on Fedora
`%cargo_generate_buildrequires` then replaces the hand-written build dependencies, and on Debian the
library and the application become two `dh-cargo` builds. The UEFI application cannot follow that
route.

## Notes for maintainers

- The release profile of every crate sets `strip`, which would leave nothing for the distribution
  tooling to extract into the `-dbgsym` and `-debuginfo` packages. Both builds override this through
  `CARGO_PROFILE_RELEASE_STRIP=false` and `CARGO_PROFILE_RELEASE_DEBUG=2`, since environment
  variables take precedence over the manifests.
- `cbindgen` writes the generated headers into `lib/target/include`, relative to the crate rather
  than to `CARGO_TARGET_DIR`. Both builds create that directory beforehand and clean it afterwards.
- Cross-building is not supported: the manual pages and the completion scripts are generated by
  running the freshly built `iclg` binary. `debian/rules` refuses a build where the host
  architecture differs from the build architecture rather than producing packages full of binaries
  for the wrong one.
- The three crates are independent Cargo workspaces with their own lock files, which is why the
  vendoring script passes each manifest to `cargo vendor --sync` and why the build enters each
  directory in turn.
- The library and the command line tool are built for every architecture. Records can only be
  collected on Intel SoCs, but decoding a record captured elsewhere is architecture independent, and
  the extraction back ends fail cleanly when the platform does not support them. Only the UEFI
  application is restricted to x86_64.
- The generated files are named after the binary, `iclg`, rather than after the crate: the `name`
  of the clap command is set explicitly in `app/src/main.rs`, since clap would otherwise derive it
  from the package name, `intel_crashlog_app`. Both packagings install `iclg*.1`, so a change there
  breaks them.
- `iclg` links the library statically, like any Rust binary: the `intel-crashlog` package does not
  depend on `libintel-crashlog1`, and the bundled crate lists are maintained per package.
- `dpkg-source` on a system with dpkg older than 1.21.3 warns three times about an `unknown
  information field 'Static-Built-Using'`. The field is correct and current Ubuntu understands it;
  the warning only means the local tooling predates it, and the container build does not show it.
