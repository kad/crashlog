#!/bin/sh
# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: MIT
#
# Runs inside the container built from Dockerfile.source. Turns a revision of the repository bind
# mounted on /src into the source packages the distribution containers build from, written to /out:
#
#   intel-crashlog-<version>.tar.xz              upstream sources, for the RPM build
#   intel-crashlog-<version>-vendor.tar.xz       vendored Rust dependencies, for the RPM build
#   intel-crashlog_<version>.orig.tar.xz         the same two under the names the Debian
#   intel-crashlog_<version>.orig-vendor.tar.xz  source package tooling expects
#   intel-crashlog_<version>-<revision>.dsc      the Debian source package
#   intel-crashlog_<version>-<revision>.debian.tar.xz
#
# This is the step that needs network access, because it vendors the dependencies. Everything that
# happens afterwards is offline.

set -eu

src=${SRC_DIR:-/src}
out=${OUT_DIR:-/out}
work=${WORK_DIR:-/work}
git_ref=${GIT_REF:-HEAD}
name=intel-crashlog

for dir in "$src" "$out"; do
    if [ ! -d "$dir" ]; then
        echo "$0: $dir is not mounted" >&2
        exit 1
    fi
done

if [ ! -e "$src/.git" ]; then
    echo "$0: $src is not a Git repository; mount the repository on $src" >&2
    exit 1
fi

# The repository is owned by the user of the host rather than by root, which Git refuses to act on
# unless it is told that the ownership is expected.
git config --global --add safe.directory '*'

# The sources are cloned rather than used in place, so that nothing in this container can write to
# the repository of the host and so that the uncommitted state of the working tree cannot leak into
# the tarballs. packaging/create-tarballs.sh exports the revision with `git archive` and vendors into
# the working tree of the clone.
repo="$work/repo"
rm -rf -- "$repo"
echo "Cloning $src at $git_ref"
git clone --quiet --no-hardlinks "$src" "$repo"
if ! git -C "$repo" checkout --quiet --detach "$git_ref" 2> /dev/null; then
    # A revision that is not reachable from any branch or tag of the clone, such as a bare commit
    # identifier on a branch that was not cloned.
    git -C "$repo" fetch --quiet origin "$git_ref"
    git -C "$repo" checkout --quiet --detach FETCH_HEAD
fi
git -C "$repo" --no-pager log -1 --format='Building %H %s'

version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$repo/app/Cargo.toml" | head -n 1)
if [ -z "$version" ]; then
    echo "$0: cannot determine the version from app/Cargo.toml" >&2
    exit 1
fi

# Vendors the dependencies and writes the four tarballs. It fails when the packaging has not been
# committed, or when vendoring refreshes the lock files, because the package builds resolve the
# dependencies with --locked and therefore need the lock files of the tarball to describe the
# vendored sources exactly.
(cd -- "$repo" && ./packaging/create-tarballs.sh -o "$out" -r HEAD)

# The Debian source package. debian/ is excluded from the upstream tarball by .gitattributes, so it
# is copied in here: unpacking the tarball and adding the packaging is what dpkg-source expects, and
# it also confirms that the tarball plus debian/ really are a complete source package rather than
# something that only builds in a working tree. The vendored dependencies stay an additional
# component of the upstream tarball, which dpkg-source recognises by its name.
sp="$work/source-package"
rm -rf -- "$sp"
mkdir -p -- "$sp"
cp -- "$out/${name}_$version.orig.tar.xz" "$out/${name}_$version.orig-vendor.tar.xz" "$sp/"
tar -xf "$sp/${name}_$version.orig.tar.xz" -C "$sp"
tar -xf "$sp/${name}_$version.orig-vendor.tar.xz" -C "$sp/$name-$version"
cp -a -- "$repo/debian" "$sp/$name-$version/debian"

echo "Building the Debian source package"
(cd -- "$sp" && dpkg-source --build "$name-$version")

cp -- "$sp"/*.dsc "$sp"/*.debian.tar.* "$out/"

# The artefacts are written through a bind mount, so they belong to root on the host unless they are
# handed back to the user who started the build.
if [ -n "${HOST_UID:-}" ]; then
    chown -R -- "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out"
fi

echo
echo "Source packages in $out:"
(cd -- "$out" && ls -1)
