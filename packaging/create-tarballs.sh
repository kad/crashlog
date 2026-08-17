#!/bin/sh
# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: MIT
#
# Creates the tarballs needed to build the Debian and RPM packages:
#
#   intel-crashlog-<version>.tar.xz         upstream sources
#   intel-crashlog-<version>-vendor.tar.xz  vendored Rust dependencies
#
# The Debian packaging expects the same two tarballs under different names,
# intel-crashlog_<version>.orig.tar.xz and intel-crashlog_<version>.orig-vendor.tar.xz, which are
# created as hard links when possible.

set -eu

usage() {
    cat <<EOF
Usage: $0 [-o OUTPUT_DIR] [-r GIT_REF]

Options:
  -o OUTPUT_DIR  Directory in which the tarballs are written (default: ../)
  -r GIT_REF     Git revision to export (default: HEAD)
  -h             Show this help message

Requires network access, since the dependencies are vendored as part of the
process. See packaging/vendor.sh.
EOF
}

output_dir=
git_ref=HEAD

while getopts ':o:r:h' opt; do
    case "$opt" in
        o) output_dir=$OPTARG ;;
        r) git_ref=$OPTARG ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

srcdir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${output_dir:-"$srcdir/.."}
output_dir=$(CDPATH='' cd -- "$output_dir" && pwd)

version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$srcdir/app/Cargo.toml" | head -n 1)
if [ -z "$version" ]; then
    echo "$0: cannot determine the version from app/Cargo.toml" >&2
    exit 1
fi

name=intel-crashlog
prefix="$name-$version"
upstream_tarball="$output_dir/$prefix.tar.xz"
vendor_tarball="$output_dir/$prefix-vendor.tar.xz"
orig_tarball="$output_dir/${name}_$version.orig.tar.xz"
orig_vendor_tarball="$output_dir/${name}_$version.orig-vendor.tar.xz"

# Vendor tarball: unpacked on top of the upstream sources at build time. The dependencies are
# vendored into the working tree rather than into a temporary directory, so that a package built
# from that tree resolves them from there and stays offline, exactly like a build from the source
# package. vendor/ is ignored by Git and by dpkg-source.
echo "Vendoring the dependencies"
"$srcdir/packaging/vendor.sh" >/dev/null

# Vendoring refreshes the lock files, and the package build runs Cargo with --locked: the lock files
# exported from Git therefore have to be the ones that describe the vendored sources. Since the
# upstream tarball is exported from Git rather than from the working tree, refuse to continue when
# they differ, instead of shipping a source package that cannot build.
locks='lib/Cargo.lock app/Cargo.lock efi/Cargo.lock'
# shellcheck disable=SC2086  # the lock files are a deliberately unquoted list of path names.
if ! (cd -- "$srcdir" && git diff --quiet "$git_ref" -- $locks); then
    cat >&2 <<EOF
$0: the lock files in the working tree differ from the ones in $git_ref:

$(cd -- "$srcdir" && git diff --stat "$git_ref" -- $locks)

Review and commit them, then run this script again. The package build resolves
the dependencies with --locked, so the lock files exported from Git have to
match the vendored sources.
EOF
    exit 1
fi

# Upstream tarball: exported from Git so that it never contains build artefacts. The debian/
# directory is excluded through .gitattributes (export-ignore) to keep the tarball pristine.
echo "Creating $upstream_tarball"
(cd -- "$srcdir" && git archive --format=tar --prefix="$prefix/" "$git_ref") |
    xz -T0 >"$upstream_tarball.tmp"
mv -- "$upstream_tarball.tmp" "$upstream_tarball"

# git archive only exports committed files, and the RPM build needs the packaging directory from the
# tarball itself. Catch the case where it has not been committed yet.
if ! tar -tf "$upstream_tarball" | grep -q "^$prefix/packaging/rpm/$name\.spec$"; then
    echo "$0: $git_ref does not contain packaging/rpm/$name.spec." >&2
    echo "Commit the packaging before creating the tarballs." >&2
    rm -f -- "$upstream_tarball"
    exit 1
fi

echo "Creating $vendor_tarball"
tar --create \
    --directory "$srcdir" \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH:-0}" \
    --owner=0 --group=0 --numeric-owner \
    --mode='go-w' \
    vendor |
    xz -T0 >"$vendor_tarball.tmp"
mv -- "$vendor_tarball.tmp" "$vendor_tarball"

# Debian expects the tarballs under different names: the vendored dependencies are an additional
# component of the upstream tarball, which dpkg-source unpacks into vendor/.
for pair in "$upstream_tarball:$orig_tarball" "$vendor_tarball:$orig_vendor_tarball"; do
    source_tarball=${pair%:*}
    target_tarball=${pair#*:}
    rm -f -- "$target_tarball"
    ln -- "$source_tarball" "$target_tarball" 2>/dev/null ||
        cp -- "$source_tarball" "$target_tarball"
done

cat <<EOF

Done:
  $upstream_tarball
  $vendor_tarball
  $orig_tarball
  $orig_vendor_tarball

The dependencies have been vendored into $srcdir/vendor,
which is where both builds resolve them from.

To build the packages:

  Debian/Ubuntu:  cd $srcdir && dpkg-buildpackage -us -uc
  Fedora/RHEL:    cp $upstream_tarball $vendor_tarball ~/rpmbuild/SOURCES/
                  rpmbuild -ba $srcdir/packaging/rpm/$name.spec
EOF
