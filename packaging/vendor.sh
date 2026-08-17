#!/bin/sh
# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: MIT
#
# Vendors the Rust dependencies of every crate of this repository into a single directory, so that
# the distribution packages can be built offline, as required by the Debian and Fedora packaging
# guidelines.
#
# This script needs network access and is therefore meant to be run by the package maintainer when
# preparing a new release, not during the package build itself.

set -eu

usage() {
    cat <<EOF
Usage: $0 [--prune-windows] [OUTPUT_DIR]

Vendors the dependencies of the lib/, app/ and efi/ crates into OUTPUT_DIR
(default: vendor/), located at the root of the repository.

Options:
  --prune-windows  Delete the vendored crates that only apply to Windows
                   targets. See the note below.

Requires network access and a Cargo installation. The Cargo.lock files of the
three crates are refreshed as a side effect.

cargo vendor has no way of restricting itself to the platforms that are actually
built, so the Windows halves of jiff and of the clap colour support are vendored
as well, and they are a large part of the tree. The Ubuntu guidance for Rust code
in main is to strip such dependencies out of the vendored sources. Doing so is
not the default here, because a build that resolves a crate cargo can no longer
find fails, and this repository has no test that would catch it: enable the
option, then confirm that an offline --locked build of all three crates still
works and update XS-Vendored-Sources-Rust in debian/control accordingly.
EOF
}

prune_windows=false
while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --prune-windows)
            prune_windows=true
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "$0: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

srcdir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
vendor_dir=${1:-"$srcdir/vendor"}

if ! command -v cargo >/dev/null 2>&1; then
    echo "$0: cargo is not installed" >&2
    exit 1
fi

rm -rf -- "$vendor_dir"

# A single vendor directory is shared by the three crates: they are independent Cargo workspaces,
# so the additional manifests have to be passed explicitly with --sync.
config=$(
    cd -- "$srcdir" && cargo vendor \
        --manifest-path lib/Cargo.toml \
        --sync app/Cargo.toml \
        --sync efi/Cargo.toml \
        "$vendor_dir"
)

# The packaging assumes that every dependency is fetched from crates.io, which lets it use a fixed
# source replacement configuration. Fail loudly if a new dependency breaks that assumption, as the
# vendored sources would then be silently ignored at build time.
if echo "$config" | grep -q '^\[source\."'; then
    cat >&2 <<EOF
$0: dependencies from sources other than crates.io have been vendored.
The source replacement configuration used by debian/rules and by
packaging/rpm/intel-crashlog.spec must be updated accordingly:

$config
EOF
    exit 1
fi

# Whole crate directories are removed rather than individual files inside them: cargo verifies the
# vendored files against the checksums in .cargo-checksum.json, so deleting part of a crate would
# require rewriting that file, while a crate cargo never asks for can simply be absent.
if [ "$prune_windows" = true ]; then
    for crate in "$vendor_dir"/winapi "$vendor_dir"/winapi-* \
        "$vendor_dir"/windows "$vendor_dir"/windows-* "$vendor_dir"/windows_*; do
        [ -d "$crate" ] || continue
        echo "Pruning $(basename -- "$crate")"
        rm -rf -- "$crate"
    done
fi

echo "Dependencies vendored into $vendor_dir"
