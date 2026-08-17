#!/bin/sh
# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: MIT
#
# Runs inside the containers built from Dockerfile.fedora and Dockerfile.opensuse. Builds a source
# RPM from the tarballs bind mounted on /in, rebuilds the binary packages from that source RPM, runs
# rpmlint over the result and leaves the packages in /out.
#
# The spec is taken out of the upstream tarball rather than from the repository, so that what is
# built is exactly what the source package ships. Building the binaries with --rebuild from the
# source RPM is the same path a distribution build service takes.
#
# Exit status: 0 on success, 3 when the packages were built but rpmlint reported problems, and any
# other non-zero value when the build itself failed.

set -eu

in=${IN_DIR:-/in}
out=${OUT_DIR:-/out}
work=${WORK_DIR:-/work}
with_efi=${WITH_EFI:-0}
run_lint=${RUN_LINT:-1}
name=intel-crashlog

for dir in "$in" "$out"; do
    if [ ! -d "$dir" ]; then
        echo "$0: $dir is not mounted" >&2
        exit 1
    fi
done

# The version is read off the vendor tarball, which is the only name in the directory that cannot be
# confused with the upstream tarball of another version.
set -- "$in/$name"-*-vendor.tar.xz
if [ ! -f "$1" ]; then
    echo "$0: no vendor tarball in $in; run the source container first" >&2
    exit 1
fi
version=$(basename -- "$1")
version=${version#"$name"-}
version=${version%-vendor.tar.xz}

if [ ! -f "$in/$name-$version.tar.xz" ]; then
    echo "$0: $in/$name-$version.tar.xz is missing" >&2
    exit 1
fi

echo "Building $name $version"
echo "Toolchain: $(rustc --version), $(cargo --version)"

top="$work/rpmbuild"
rm -rf -- "$top"
mkdir -p -- "$top/SOURCES" "$top/SPECS"
cp -- "$in/$name-$version.tar.xz" "$in/$name-$version-vendor.tar.xz" "$top/SOURCES/"
tar -xOf "$in/$name-$version.tar.xz" "$name-$version/packaging/rpm/$name.spec" \
    > "$top/SPECS/$name.spec"

# Macro definitions that apply to both rpmbuild runs.
set -- --define "_topdir $top"

if [ "$with_efi" = 1 ]; then
    # Adds the efi subpackage. This needs network access, so the container is started without
    # --network none in that case; see packaging/docker/build.sh.
    set -- "$@" --with efi
fi

# openSUSE only splits the debugging information out into -debuginfo packages when the build is asked
# for them, which is what its build service does; Fedora does it by default. Without this the
# packages would keep the debugging information that the spec deliberately does not strip, and
# rpmlint would report unstripped binaries.
if [ -r /etc/os-release ] && grep -Eq '^ID(_LIKE)?=.*suse' /etc/os-release; then
    set -- "$@" --define "_build_create_debug 1"
fi

echo "Building the source RPM"
rpmbuild -bs "$@" "$top/SPECS/$name.spec"

srpm=$(find "$top/SRPMS" -name '*.src.rpm' | head -n 1)
if [ -z "$srpm" ]; then
    echo "$0: no source RPM was produced" >&2
    exit 1
fi

echo "Rebuilding $srpm"
rpmbuild --rebuild "$@" "$srpm"

mkdir -p -- "$out"
cp -- "$srpm" "$out/"
find "$top/RPMS" -name '*.rpm' -exec cp -- '{}' "$out/" ';'

lint_status=0
if [ "$run_lint" = 1 ]; then
    echo
    echo "Running rpmlint"
    # The source RPM is checked as well as the binaries: several of the tags that matter for a
    # package review, such as the ones about the spec itself, are only reported for it.
    if rpmlint "$out"/*.rpm > "$out/rpmlint.txt" 2>&1; then
        echo "rpmlint reported no problems"
    else
        lint_status=3
        echo "rpmlint reported problems, see rpmlint.txt"
    fi
    sed -e 's/^/  /' "$out/rpmlint.txt"
fi

if [ -n "${HOST_UID:-}" ]; then
    chown -R -- "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out"
fi

echo
echo "Packages in $out:"
(cd -- "$out" && ls -1)

exit "$lint_status"
