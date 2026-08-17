# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: MIT

# The UEFI application is not built by default: the x86_64-unknown-uefi target is not covered by
# the Rust toolchain shipped by the distribution, so a rustup managed toolchain providing that
# target is required. Enable it with: rpmbuild --with efi
%bcond_with efi

%if %{with efi}
%ifnarch x86_64
%{error:The efi subpackage can only be built on x86_64.}
%endif
%endif

# The Rust dependencies are bundled rather than taken from the rust-* packages of the distribution:
# the sources are vendored into the vendor/ directory by packaging/vendor.sh and the build never
# reaches the network. Most of what the library and the command line tool need does exist in Fedora,
# but the crates of the UEFI application do not, and no rust-std is shipped for
# x86_64-unknown-uefi; bundling keeps the three crates of this repository building the same way and
# keeps the result reproducible against the lock files. Every package that contains compiled Rust
# code therefore carries the corresponding `Provides: bundled(crate(...))` entries, and ships the
# licensing reports that %%build generates.
%global crate_lib intel_crashlog
%global soversion 1

# This spec builds on Fedora, on RHEL and on openSUSE. Two kinds of difference are handled below and
# they are tested for differently on purpose. Whether the macros of cargo-rpm-macros exist is a
# property of the build environment, so it is asked with %%{defined}: the fallbacks then also apply
# to any other distribution that has a Rust toolchain but not those macros. Package naming and the
# ldconfig scriptlets are distribution policy rather than a capability, so those are keyed on
# 0%%{?suse_version}.
#
# cargo-rpm-macros keeps CARGO_HOME under the build directory, and %%prep writes the source
# replacement stanza for the vendored dependencies there. Where the macros are absent the same
# location is used, so that the rest of the spec does not have to care.
%{!?cargo_home:%global cargo_home %{_builddir}/.cargo}

# openSUSE has no distribution wide set of rustc flags. Only the linker flags matter here, as none of
# the crates compiles C code, and full RELRO with immediate binding is what the hardening checks of
# both distributions look for.
%{!?build_rustflags:%global build_rustflags -Clink-arg=-Wl,-z,relro -Clink-arg=-Wl,-z,now}

# rpm 4.19 and later report the job count the build was given; older releases do not define it.
%{!?_smp_build_ncpus:%global _smp_build_ncpus 1}

# --all-features is, for the library, the default features plus `ffi`, which generates the C and
# C++ headers and sets the SONAME of the shared library. --locked keeps the build from re-resolving
# the dependency tree: the lock files are part of the sources and describe exactly what vendor/
# contains. The name is prefixed to avoid clashing with the %%cargo_flags macro of cargo-rpm-macros.
# --verbose puts the rustc invocations in the build log, and the job count is the one rpm was given.
%global crashlog_cargo_flags --release --locked --all-features --offline --verbose -j%{_smp_build_ncpus}

Name:           intel-crashlog
Version:        1.1.0
Release:        %{?autorelease}%{!?autorelease:1%{?dist}}
Summary:        Extract and decode Intel Crash Log records

# The sources of this repository are MIT. The binaries statically link their Rust dependencies, so
# the licenses of the bundled crates are part of the effective license of the packages: MPL-2.0
# comes from the uguid crate, which every binary of this project depends on. Refresh the expression
# below whenever the dependencies change: `packaging/vendor-licenses.sh` reports the expression of
# every crate per package, and %%cargo_license_summary prints the same information, grouped by
# license, into the build log.
License:        MIT AND (MIT OR Apache-2.0) AND (Unlicense OR MIT) AND Unicode-3.0 AND MPL-2.0
URL:            https://github.com/intel/crashlog

# Both tarballs are produced by packaging/create-tarballs.sh, which exports the sources from the Git
# repository and vendors the Rust dependencies. Neither is a plain download, which is why Source0 is
# a bare file name rather than the URL the packaging guidelines ask for: the tarball GitHub generates
# for a tag unpacks under a different directory name, and the vendored sources have to be produced
# from the very lock files that are exported next to them, because the build uses --locked.
#
# Before a submission to Fedora, switch Source0 to
#   https://github.com/intel/crashlog/archive/v%%{version}/%%{name}-%%{version}.tar.gz
# and adjust the -n argument of %%autosetup to the directory name inside that tarball. Source1 stays
# a locally generated file, as it is for every vendored Rust package.
Source0:        %{name}-%{version}.tar.xz
Source1:        %{name}-%{version}-vendor.tar.xz

# Records can only be collected on Intel SoCs, but decoding a record that was captured elsewhere is
# architecture independent and is a supported use case, so the package is not restricted to x86_64.
# Only the UEFI application is, and it is not built by default.

BuildRequires:  cargo >= 1.85
BuildRequires:  rust >= 1.85
# rustc links through the C compiler driver, which is not part of a minimal build root.
BuildRequires:  gcc
%if 0%{?suse_version}
# openSUSE has no cargo-rpm-macros. The licensing reports the guidelines of both distributions expect
# for bundled code are generated from the vendored tree by packaging/vendor-licenses.sh instead, which
# needs nothing but an interpreter. See the licensing section of %%build.
BuildRequires:  python3-base
%else
# %%cargo_license, %%cargo_license_summary and %%cargo_vendor_manifest, which the Rust packaging
# guidelines require for bundled dependencies, come from cargo-rpm-macros 24 and later.
BuildRequires:  cargo-rpm-macros >= 24
%endif
%if %{with efi}
# rustup is not packaged in Fedora, so this cannot be expressed as a BuildRequires: the toolchain it
# manages has to be available in the build environment, which is one more reason why the efi
# subpackage is not suitable for an official distribution build. See the comment above %%bcond.
%endif

# BUNDLED-PROVIDES-BEGIN app
# Crates that end up in the iclg binary: the closure of the regular dependencies of app/, resolved
# for the x86_64-unknown-linux-gnu target. Dependencies that only exist at build time and the test
# only ones are not listed, since their code is not shipped, and neither are the crates that are
# reachable only through a cfg(windows) target section. The procedural macro crates are listed,
# because they are part of that closure and their license terms therefore apply to what is built
# here.
# Refresh with packaging/vendor-licenses.sh -f rpm whenever app/Cargo.lock changes.
#
# These entries are written out rather than left to the automatic generator that recent versions of
# cargo-rpm-macros run over an installed cargo-vendor.txt. Check `rpm -q --provides` on the built
# packages: where that generator is present, its output supersedes these blocks, which can then be
# deleted. Where it is not, or where it lists crates that are not linked into the binary because it
# does not filter by target, these are the accurate lists.
Provides:       bundled(crate(acpi)) = 5.2.0
Provides:       bundled(crate(aho-corasick)) = 1.1.4
Provides:       bundled(crate(anstream)) = 1.0.0
Provides:       bundled(crate(anstyle)) = 1.0.14
Provides:       bundled(crate(anstyle-parse)) = 1.0.0
Provides:       bundled(crate(anstyle-query)) = 1.1.5
Provides:       bundled(crate(bit_field)) = 0.10.3
Provides:       bundled(crate(bitflags)) = 2.13.0
Provides:       bundled(crate(clap)) = 4.6.1
Provides:       bundled(crate(clap_builder)) = 4.6.0
Provides:       bundled(crate(clap_complete)) = 4.6.9
Provides:       bundled(crate(clap_derive)) = 4.6.1
Provides:       bundled(crate(clap_lex)) = 1.1.0
Provides:       bundled(crate(clap_mangen)) = 0.2.33
Provides:       bundled(crate(colorchoice)) = 1.0.5
Provides:       bundled(crate(env_filter)) = 1.0.1
Provides:       bundled(crate(env_logger)) = 0.11.10
Provides:       bundled(crate(heck)) = 0.5.0
Provides:       bundled(crate(is_terminal_polyfill)) = 1.70.2
Provides:       bundled(crate(itoa)) = 1.0.18
Provides:       bundled(crate(jiff)) = 0.2.28
Provides:       bundled(crate(jiff-static)) = 0.2.28
Provides:       bundled(crate(log)) = 0.4.32
Provides:       bundled(crate(memchr)) = 2.8.1
Provides:       bundled(crate(portable-atomic)) = 1.13.1
Provides:       bundled(crate(portable-atomic-util)) = 0.2.7
Provides:       bundled(crate(proc-macro2)) = 1.0.106
Provides:       bundled(crate(quote)) = 1.0.45
Provides:       bundled(crate(regex)) = 1.12.3
Provides:       bundled(crate(regex-automata)) = 0.4.14
Provides:       bundled(crate(regex-syntax)) = 0.8.10
Provides:       bundled(crate(roff)) = 1.1.1
Provides:       bundled(crate(serde)) = 1.0.228
Provides:       bundled(crate(serde_core)) = 1.0.228
Provides:       bundled(crate(serde_derive)) = 1.0.228
Provides:       bundled(crate(serde_json)) = 1.0.150
Provides:       bundled(crate(strsim)) = 0.11.1
Provides:       bundled(crate(syn)) = 2.0.117
Provides:       bundled(crate(uguid)) = 2.2.1
Provides:       bundled(crate(unicode-ident)) = 1.0.24
Provides:       bundled(crate(utf8parse)) = 0.2.2
Provides:       bundled(crate(zmij)) = 1.0.21
# BUNDLED-PROVIDES-END

%description
Modern Intel SoCs automatically record hardware state during fatal crashes, such
as machine check exceptions, triple faults or unexpected resets, into on-die
memory. When valid records are present during boot, the firmware copies them into
the ACPI Boot Error Record Table so that the operating system can retrieve them.

This package provides iclg, a command line tool that extracts those records from
the running platform and decodes them into human readable JSON. It can also
triage records, list the collection sources available on the platform and enable,
disable or trigger a collection on demand.

# The shared library gets a package of its own so that an incompatible release can be co-installed
# with this one. Fedora names it after the source package, as intel-crashlog-libs; the openSUSE shared
# library policy names it after the library and its SONAME, as libintel_crashlog1, and its rpmlint
# rejects anything else. The name is used for the subpackage, for its scriptlets and for the
# dependency of the devel package, so it is kept in one macro. `%%package -n` takes it verbatim
# instead of appending it to the name of the source package.
%if 0%{?suse_version}
%global libs_package lib%{crate_lib}%{soversion}
%else
%global libs_package %{name}-libs
%endif

%package -n %{libs_package}
Summary:        Library to extract and decode Intel Crash Log records
License:        MIT AND (MIT OR Apache-2.0) AND (Unlicense OR MIT) AND Unicode-3.0 AND MPL-2.0

# BUNDLED-PROVIDES-BEGIN lib
# Crates that end up in the shared library: the closure of the regular dependencies of lib/,
# resolved for the x86_64-unknown-linux-gnu target. See the block of the main package. The build
# dependencies cbindgen and cargo-emit and the test dependency tempfile are in lib/Cargo.lock but
# not here, since none of their code is linked into the library.
# Refresh with packaging/vendor-licenses.sh -f rpm whenever lib/Cargo.lock changes.
Provides:       bundled(crate(acpi)) = 5.2.0
Provides:       bundled(crate(bit_field)) = 0.10.3
Provides:       bundled(crate(bitflags)) = 2.13.0
Provides:       bundled(crate(itoa)) = 1.0.18
Provides:       bundled(crate(log)) = 0.4.33
Provides:       bundled(crate(memchr)) = 2.8.2
Provides:       bundled(crate(proc-macro2)) = 1.0.106
Provides:       bundled(crate(quote)) = 1.0.46
Provides:       bundled(crate(serde)) = 1.0.228
Provides:       bundled(crate(serde_core)) = 1.0.228
Provides:       bundled(crate(serde_derive)) = 1.0.228
Provides:       bundled(crate(serde_json)) = 1.0.150
Provides:       bundled(crate(syn)) = 2.0.118
Provides:       bundled(crate(uguid)) = 2.2.1
Provides:       bundled(crate(unicode-ident)) = 1.0.24
Provides:       bundled(crate(zmij)) = 1.0.21
# BUNDLED-PROVIDES-END

%description -n %{libs_package}
This package provides the shared library used to extract Intel Crash Log records
from a platform and to decode them into a register tree, together with the
product specific collateral required for decoding.

%package devel
Summary:        Development files for the Intel Crash Log library
# This package only contains the headers generated from the sources of this repository, the
# pkg-config file and a symbolic link: no bundled code ends up in it.
License:        MIT
Requires:       %{libs_package}%{?_isa} = %{version}-%{release}

%description devel
This package provides the C and C++ headers, the pkg-config file and the
symbolic link needed to build applications against the Intel Crash Log library.

%if %{with efi}
%package efi
Summary:        Extract Intel Crash Log records from the UEFI shell
# Same expression as the main package: the MPL-2.0 term covers uguid, which every binary of this
# project links, and the uefi crates, which only this subpackage links.
License:        MIT AND (MIT OR Apache-2.0) AND (Unlicense OR MIT) AND Unicode-3.0 AND MPL-2.0

# BUNDLED-PROVIDES-BEGIN efi
# Crates that end up in the UEFI application: the closure of the regular dependencies of efi/,
# resolved for the x86_64-unknown-uefi target. See the block of the main package.
# Refresh with packaging/vendor-licenses.sh -f rpm whenever efi/Cargo.lock changes.
Provides:       bundled(crate(acpi)) = 5.2.0
Provides:       bundled(crate(bit_field)) = 0.10.3
Provides:       bundled(crate(bitflags)) = 2.13.0
Provides:       bundled(crate(cfg-if)) = 1.0.4
Provides:       bundled(crate(itoa)) = 1.0.18
Provides:       bundled(crate(log)) = 0.4.33
Provides:       bundled(crate(memchr)) = 2.8.2
Provides:       bundled(crate(proc-macro2)) = 1.0.106
Provides:       bundled(crate(ptr_meta)) = 0.3.1
Provides:       bundled(crate(ptr_meta_derive)) = 0.3.1
Provides:       bundled(crate(quote)) = 1.0.46
Provides:       bundled(crate(serde)) = 1.0.228
Provides:       bundled(crate(serde_core)) = 1.0.228
Provides:       bundled(crate(serde_derive)) = 1.0.228
Provides:       bundled(crate(serde_json)) = 1.0.150
Provides:       bundled(crate(syn)) = 2.0.118
Provides:       bundled(crate(ucs2)) = 0.3.3
Provides:       bundled(crate(uefi)) = 0.37.0
Provides:       bundled(crate(uefi-macros)) = 0.19.0
Provides:       bundled(crate(uefi-raw)) = 0.14.0
Provides:       bundled(crate(uguid)) = 2.2.1
Provides:       bundled(crate(unicode-ident)) = 1.0.24
Provides:       bundled(crate(zmij)) = 1.0.21
# BUNDLED-PROVIDES-END

%description efi
This package provides iclg.efi, a UEFI application that extracts Intel Crash Log
records from the ACPI Boot Error Record Table before an operating system is
started, and either saves them on an EFI system partition or displays them on the
UEFI console.

The application is not run on the installed system: copy it to a FAT32 partition
and start it from the UEFI shell.
%endif

%prep
%autosetup -n %{name}-%{version} -p1 -a1

# Build the three crates of this repository against the vendored sources. The configuration goes
# into %%{cargo_home}, which is %%{_builddir}/.cargo, for two reasons: Cargo reads
# $CARGO_HOME/config.toml, and %%__cargo, through which the licensing macros below run, forces
# CARGO_HOME to exactly that directory, so a file anywhere else would leave those macros resolving
# against crates.io and failing offline. Cargo also finds it by walking up from each crate
# directory, since %%{_builddir} is an ancestor of the unpacked sources, which is what covers the
# plain `cargo build` invocations in %%build. The replacement directory has to be an absolute path,
# because each crate is built from its own directory.
#
# This is what %%cargo_prep writes for a vendored build, but that macro also fixes the target
# directory, while each crate here needs its own, and its command line has changed between releases
# of cargo-rpm-macros. The stanza is therefore written out, and the rest of the environment the
# macro would set up is exported in %%build.
mkdir -p %{cargo_home}
cat > %{cargo_home}/config.toml <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$PWD/vendor"
EOF

%build
export CARGO_NET_OFFLINE=true
export CARGO_HOME="%{cargo_home}"
export RUSTFLAGS="%{build_rustflags}"

# The crates set `strip` in their release profile, which would leave nothing to extract into the
# debuginfo packages. Environment variables take precedence over the manifests.
export CARGO_PROFILE_RELEASE_STRIP=false
export CARGO_PROFILE_RELEASE_DEBUG=2

# Each crate gets its own target directory. The library is built with the `ffi` feature, which sets
# the SONAME, while the application depends on it with the default features: sharing a target
# directory would let one build overwrite the shared library produced by the other.
build_dir="$PWD/build"
mkdir -p "$build_dir"

# cbindgen writes the generated headers next to the crate rather than into CARGO_TARGET_DIR.
mkdir -p lib/target/include
(cd lib && CARGO_TARGET_DIR="$build_dir/lib" cargo build %{crashlog_cargo_flags})
(cd app && CARGO_TARGET_DIR="$build_dir/app" cargo build %{crashlog_cargo_flags})

%if %{with efi}
# The distribution toolchain has no standard library for x86_64-unknown-uefi, so the target is
# provided by a rustup managed toolchain installed under the build directory. It has to be called
# through `rustup run`, since `cargo` on PATH is the one from the cargo package. Nothing can be
# extracted into a -debuginfo package from a PE binary, so it is stripped instead.
#
# %%build_rustflags is deliberately not passed on: it describes how to link an ELF executable
# against the system libraries, with options such as -Clink-arg=-Wl,-z,now, and the UEFI target
# links PE binaries with rust-lld, which does not accept them.
export RUSTUP_HOME="$PWD/.rustup"
rustup toolchain install --profile minimal --target x86_64-unknown-uefi stable
(cd efi && CARGO_TARGET_DIR="$build_dir/efi" CARGO_PROFILE_RELEASE_STRIP=true RUSTFLAGS= \
    rustup run stable cargo build --release --locked --offline --target x86_64-unknown-uefi)
%endif

# The manual pages and the shell completion scripts are derived from the command line definition by
# the tool itself, so that they cannot drift from the actual interface.
"$build_dir/app/release/iclg" generate-assets --output-dir build/assets

sed -e 's|@PREFIX@|%{_prefix}|' \
    -e 's|@LIBDIR@|%{_libdir}|' \
    -e 's|@INCLUDEDIR@|%{_includedir}|' \
    -e 's|@VERSION@|%{version}|' \
    packaging/intel_crashlog.pc.in > build/%{crate_lib}.pc

# The repository and the application both have a README.md, and %%doc installs documentation under
# its base name: they are renamed so that the two can be shipped side by side.
mkdir -p "$build_dir/doc"
cp -p README.md "$build_dir/doc/README.md"
cp -p app/README.md "$build_dir/doc/README.iclg.md"

# Licensing of the bundled crates, which the Rust packaging guidelines require to be shipped with
# the packages: LICENSE.dependencies records the license expression of every crate that is built in
# and cargo-vendor.txt the exact versions that were vendored. One report is produced per crate of
# this repository, since each of them ends up in a different package, and %%files picks up whatever
# lands in the directory.
mkdir -p "$build_dir/licenses"
%if %{defined cargo_license}
# The macros of cargo-rpm-macros resolve the dependency graph for the build platform and take no
# target, so the report of efi/ describes its dependencies as they would be resolved for the host
# rather than for x86_64-unknown-uefi; the `Provides: bundled(crate(...))` entries above are filtered
# by target.
for crate in lib app efi; do
    report_dir="$build_dir/licenses/$crate"
    mkdir -p "$report_dir"
    (cd "$crate" && %{cargo_license_summary})
    (cd "$crate" && %{cargo_license}) > "$report_dir/LICENSE.dependencies"
    # %%cargo_vendor_manifest redirects into a file called cargo-vendor.txt rather than to standard
    # output, so it is moved into place afterwards. Which directory it lands in has changed between
    # releases of cargo-rpm-macros, hence both candidates.
    (cd "$crate" && %{cargo_vendor_manifest})
    if [ -f "$crate/cargo-vendor.txt" ]; then
        mv "$crate/cargo-vendor.txt" "$report_dir/cargo-vendor.txt"
    else
        mv cargo-vendor.txt "$report_dir/cargo-vendor.txt"
    fi
    # %%cargo_vendor_manifest lists the other two crates of this repository as ordinary
    # dependencies, since app/ and efi/ depend on lib/ through a path dependency in Cargo.toml.
    # Their entries look like "intel_crashlog v1.1.0 (/path/to/lib)", with no registry or git
    # source: the automatic bundled(crate(...)) provides generator that later scans this file
    # cannot parse that shape and aborts the whole build, so path dependencies are dropped here.
    # They are not vendored crates anyway; they are this package's own source.
    sed -i -E '/ \(\/[^)]*\)$/d' "$report_dir/cargo-vendor.txt"
done
%else
# Without cargo-rpm-macros the report is generated from the vendored tree, which needs neither cargo
# nor a resolve step and therefore also works where no standard library for the UEFI target is
# installed. It covers the whole tree rather than the dependency closure of one crate, so the three
# packages get the same file: that describes the source package as it is shipped, which is the same
# thing the `Files: vendor/*` stanzas of the Debian copyright file do. What is linked into each
# individual binary is in the `Provides: bundled(crate(...))` entries above.
./packaging/vendor-licenses.sh -f manifest > "$build_dir/licenses/LICENSE.dependencies"
# Into the build log, for the same reason %%cargo_license_summary is on Fedora.
sed -n '/^# [0-9]* bundled crates/,/^$/p' "$build_dir/licenses/LICENSE.dependencies"
for crate in lib app efi; do
    mkdir -p "$build_dir/licenses/$crate"
    cp -p "$build_dir/licenses/LICENSE.dependencies" "$build_dir/licenses/$crate/"
done
rm -f "$build_dir/licenses/LICENSE.dependencies"
%endif

# The license texts of the bundled crates themselves: MIT, Apache-2.0 and MPL-2.0 all require the
# notice to be reproduced, which the reports above do not do.
license_dir="$build_dir/bundled-licenses"
rm -rf "$license_dir"
for crate_dir in vendor/*/; do
    crate=$(basename "$crate_dir")
    for file in "$crate_dir"LICENSE* "$crate_dir"COPYING* "$crate_dir"NOTICE* "$crate_dir"UNLICENSE*; do
        test -f "$file" || continue
        mkdir -p "$license_dir/$crate"
        install -p -m 0644 "$file" "$license_dir/$crate/"
    done
done

%install
# Command line tool.
install -D -p -m 0755 build/app/release/iclg %{buildroot}%{_bindir}/iclg

install -d %{buildroot}%{_mandir}/man1
install -p -m 0644 build/assets/*.1 %{buildroot}%{_mandir}/man1/

# The completion directories belong to the bash-completion, zsh and fish packages, which are not
# pulled in: the scripts are inert until the corresponding shell is installed.
install -D -p -m 0644 build/assets/iclg.bash \
    %{buildroot}%{_datadir}/bash-completion/completions/iclg
install -D -p -m 0644 build/assets/_iclg \
    %{buildroot}%{_datadir}/zsh/site-functions/_iclg
install -D -p -m 0644 build/assets/iclg.fish \
    %{buildroot}%{_datadir}/fish/vendor_completions.d/iclg.fish

# Shared library. The real file carries the full version, the SONAME is a symbolic link to it and
# the development link points at the SONAME.
install -D -p -m 0755 build/lib/release/lib%{crate_lib}.so \
    %{buildroot}%{_libdir}/lib%{crate_lib}.so.%{version}
ln -s lib%{crate_lib}.so.%{version} %{buildroot}%{_libdir}/lib%{crate_lib}.so.%{soversion}
ln -s lib%{crate_lib}.so.%{soversion} %{buildroot}%{_libdir}/lib%{crate_lib}.so

# Development files.
install -D -p -m 0644 lib/target/include/%{crate_lib}.h \
    %{buildroot}%{_includedir}/%{crate_lib}.h
install -D -p -m 0644 lib/target/include/%{crate_lib}.hpp \
    %{buildroot}%{_includedir}/%{crate_lib}.hpp
install -D -p -m 0644 build/%{crate_lib}.pc \
    %{buildroot}%{_libdir}/pkgconfig/%{crate_lib}.pc

%if %{with efi}
# The UEFI application is not executed on the installed system: it is copied to an EFI system
# partition and started from the UEFI shell.
install -D -p -m 0644 build/efi/x86_64-unknown-uefi/release/iclg.efi \
    %{buildroot}%{_libexecdir}/%{name}/efi/iclg.efi
%endif

%check
export CARGO_NET_OFFLINE=true
export CARGO_HOME="%{cargo_home}"
export RUSTFLAGS="%{build_rustflags}"
export CARGO_PROFILE_RELEASE_STRIP=false
export CARGO_PROFILE_RELEASE_DEBUG=2
build_dir="$PWD/build"

# Reuses the artefacts of the %%build section. Only the library has a test suite: the app crate has
# no tests, and the tests of the efi crate would have to run on the UEFI target.
(cd lib && CARGO_TARGET_DIR="$build_dir/lib" cargo test %{crashlog_cargo_flags})

# The generated manual pages and completions must describe the tool that is being packaged.
build/app/release/iclg --version | grep -q '%{version}'

%files
%license LICENSE
%license build/bundled-licenses
# LICENSE.dependencies, plus cargo-vendor.txt where cargo-rpm-macros generated one. The directory is
# globbed because which of the two reports exists depends on the distribution; see %%build.
%license build/licenses/app/*
%doc build/doc/README.md
%doc build/doc/README.iclg.md
%doc SECURITY.md
%{_bindir}/iclg
%{_mandir}/man1/iclg*.1*
# The completion directories are owned here as well: the packages that normally own them are not
# depended upon, since the scripts are inert until the matching shell is installed.
%dir %{_datadir}/bash-completion
%dir %{_datadir}/bash-completion/completions
%{_datadir}/bash-completion/completions/iclg
%dir %{_datadir}/zsh
%dir %{_datadir}/zsh/site-functions
%{_datadir}/zsh/site-functions/_iclg
%dir %{_datadir}/fish
%dir %{_datadir}/fish/vendor_completions.d
%{_datadir}/fish/vendor_completions.d/iclg.fish

%if 0%{?suse_version}
# On Fedora ldconfig is not called from a scriptlet: rpm runs it through a file trigger of the glibc
# package. openSUSE has no such trigger and expects every package that installs a shared library to
# call it itself.
%post -n %{libs_package} -p /sbin/ldconfig
%postun -n %{libs_package} -p /sbin/ldconfig
%endif

%files -n %{libs_package}
%license LICENSE
%license build/bundled-licenses
%license build/licenses/lib/*
%{_libdir}/lib%{crate_lib}.so.%{soversion}
%{_libdir}/lib%{crate_lib}.so.%{version}

%files devel
%license LICENSE
%doc lib/README.md
%{_includedir}/%{crate_lib}.h
%{_includedir}/%{crate_lib}.hpp
%{_libdir}/lib%{crate_lib}.so
%{_libdir}/pkgconfig/%{crate_lib}.pc

%if %{with efi}
%files efi
%license LICENSE
%license build/bundled-licenses
%license build/licenses/efi/*
%doc efi/README.md
%dir %{_libexecdir}/%{name}
%dir %{_libexecdir}/%{name}/efi
%{_libexecdir}/%{name}/efi/iclg.efi
%endif

%changelog
%{?autochangelog}%{!?autochangelog:
* Fri Aug 14 2026 Intel Corporation <crashlog@intel.com> - 1.1.0-1
- Initial package.
}
