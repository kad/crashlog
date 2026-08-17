#!/bin/sh
# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: MIT
#
# Runs inside the container built from Dockerfile.ubuntu. Unpacks the Debian source package bind
# mounted on /in, builds it, runs lintian over the result and leaves the packages in /out.
#
# Exit status: 0 on success, 3 when the packages were built but lintian reported problems, and any
# other non-zero value when the build itself failed.

set -eu

in=${IN_DIR:-/in}
out=${OUT_DIR:-/out}
work=${WORK_DIR:-/work}
with_efi=${WITH_EFI:-0}
run_lint=${RUN_LINT:-1}

for dir in "$in" "$out"; do
    if [ ! -d "$dir" ]; then
        echo "$0: $dir is not mounted" >&2
        exit 1
    fi
done

set -- "$in"/*.dsc
if [ ! -f "$1" ]; then
    echo "$0: no source package in $in; run the source container first" >&2
    exit 1
fi
dsc=$1
if [ $# -gt 1 ]; then
    echo "$0: more than one source package in $in" >&2
    exit 1
fi

echo "Toolchain: $(rustc --version), $(cargo --version)"

# The source package is copied out of the read only mount: dpkg-buildpackage rebuilds the source
# package as part of the run, and dpkg-source looks for the upstream tarballs in the parent of the
# directory it unpacked.
build="$work/build"
rm -rf -- "$build"
mkdir -p -- "$build"
cp -- "$in"/*.dsc "$in"/*.orig*.tar.* "$in"/*.debian.tar.* "$build/"

cd -- "$build"
dpkg-source --extract "$(basename -- "$dsc")"

srcdir=$(find . -mindepth 1 -maxdepth 1 -type d -name 'intel-crashlog-*' | head -n 1)
if [ -z "$srcdir" ]; then
    echo "$0: the source package did not unpack into a directory" >&2
    exit 1
fi

# The vendored sources have to be there, since the build runs offline and this container has no
# network: without them Cargo would fail on the first dependency instead of saying what is missing.
if [ ! -d "$srcdir/vendor" ]; then
    echo "$0: $srcdir/vendor is missing; the vendor component of the source package did not unpack" >&2
    exit 1
fi

# parallel=N is the interface the Debian packaging uses to cap the number of concurrent jobs.
DEB_BUILD_OPTIONS="parallel=$(nproc)"
export DEB_BUILD_OPTIONS

set -- --no-sign
if [ "$with_efi" = 1 ]; then
    # Adds the intel-crashlog-efi package. This needs network access, so the container is started
    # without --network none in that case; see packaging/docker/build.sh.
    set -- "$@" -P pkg.intel-crashlog.efi
fi

echo "Building with dpkg-buildpackage $*"
(cd -- "$srcdir" && dpkg-buildpackage "$@")

mkdir -p -- "$out"
for artefact in "$build"/*.deb "$build"/*.ddeb "$build"/*.changes "$build"/*.buildinfo \
    "$build"/*.dsc "$build"/*.debian.tar.*; do
    [ -f "$artefact" ] || continue
    cp -- "$artefact" "$out/"
done

lint_status=0
if [ "$run_lint" = 1 ]; then
    echo
    echo "Running lintian"
    # --info explains every tag, and --display-info adds the informational ones, which is the level
    # of detail that is useful when the packaging is being reviewed rather than uploaded. The report
    # is kept next to the packages, because it is long.
    if lintian --info --display-info "$build"/*.changes > "$out/lintian.txt" 2>&1; then
        echo "lintian reported no problems"
    else
        lint_status=3
        echo "lintian reported problems, see lintian.txt"
    fi
    sed -e 's/^/  /' "$out/lintian.txt"
fi

if [ -n "${HOST_UID:-}" ]; then
    chown -R -- "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out"
fi

echo
echo "Packages in $out:"
(cd -- "$out" && ls -1)

exit "$lint_status"
