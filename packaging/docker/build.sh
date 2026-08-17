#!/bin/sh
# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: MIT
#
# Builds the distribution packages of this repository in containers, one per distribution, so that
# nothing has to be installed on the machine that runs it and so that every build starts from a clean
# root.
#
# The flow mirrors what a distribution build service does. A first container exports the requested
# revision, vendors the Rust dependencies and produces the source packages; that is the only step
# with network access. Each distribution container then builds from those source packages with the
# network switched off, which is what proves that the vendored sources are complete, and runs the
# linter of the distribution over the result.

set -eu

srcdir=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
docker=${DOCKER:-docker}
image_prefix=${IMAGE_PREFIX:-intel-crashlog-build}
all_targets='ubuntu fedora opensuse'

usage() {
    cat <<EOF
Usage: $0 [OPTION]... [TARGET]...

Builds the packages of this repository inside containers. TARGET is one or more
of: $all_targets (default: all of them).

Options:
  -o OUTPUT_DIR  Directory for the source packages and the built packages
                 (default: ../intel-crashlog-packages, next to the repository)
  -r GIT_REF     Revision to build (default: HEAD). The packaging has to be
                 committed in it, since the containers build from a source
                 package exported from Git rather than from the working tree.
  --efi          Also build the UEFI application. This needs a rustup managed
                 toolchain for the x86_64-unknown-uefi target, so the build
                 containers are given network access, and the packages are
                 therefore not reproducible from the source package alone.
  --no-lint      Skip lintian and rpmlint.
  --skip-source  Reuse the source packages already in OUTPUT_DIR/source instead
                 of exporting and vendoring again. Useful when iterating on the
                 packaging of one distribution.
  -h, --help     Show this help message

Environment:
  DOCKER         Container command to use (default: docker). Set DOCKER=podman
                 to use Podman.
  IMAGE_PREFIX   Prefix of the image names (default: $image_prefix)

The output directory ends up with one subdirectory per stage:

  OUTPUT_DIR/source    the two upstream tarballs and the Debian source package
  OUTPUT_DIR/ubuntu    .deb packages, plus the lintian report
  OUTPUT_DIR/fedora    .rpm packages, plus the rpmlint report
  OUTPUT_DIR/opensuse  .rpm packages, plus the rpmlint report

A linter that reports problems does not stop the other builds: the packages are
kept, the reports are written, and this script exits non-zero at the end with a
summary of what failed.
EOF
}

output_dir=
git_ref=HEAD
with_efi=0
run_lint=1
skip_source=0
targets=

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        -o)
            [ $# -ge 2 ] || { echo "$0: -o needs an argument" >&2; exit 1; }
            output_dir=$2
            shift 2
            ;;
        -r)
            [ $# -ge 2 ] || { echo "$0: -r needs an argument" >&2; exit 1; }
            git_ref=$2
            shift 2
            ;;
        --efi)
            with_efi=1
            shift
            ;;
        --no-lint)
            run_lint=0
            shift
            ;;
        --skip-source)
            skip_source=1
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

for target in "$@"; do
    case " $all_targets " in
        *" $target "*) targets="$targets $target" ;;
        *)
            echo "$0: unknown target: $target" >&2
            echo "$0: known targets: $all_targets" >&2
            exit 1
            ;;
    esac
done
targets=${targets:-$all_targets}
targets=${targets# }

if ! command -v "$docker" > /dev/null 2>&1; then
    echo "$0: $docker is not installed; set DOCKER to the container command to use" >&2
    exit 1
fi
if ! "$docker" info > /dev/null 2>&1; then
    echo "$0: $docker is installed but not usable; is the service running and are you in its group?" >&2
    exit 1
fi

output_dir=${output_dir:-"$srcdir/../intel-crashlog-packages"}
mkdir -p -- "$output_dir"
output_dir=$(CDPATH='' cd -- "$output_dir" && pwd)

# The containers build from a source package exported with `git archive`, so anything that is only in
# the working tree is not part of the build. Say so before spending several minutes on vendoring.
if ! git -C "$srcdir" rev-parse --verify --quiet "$git_ref^{commit}" > /dev/null; then
    echo "$0: $git_ref is not a revision of $srcdir" >&2
    exit 1
fi
missing=
for path in debian/control debian/rules packaging/rpm/intel-crashlog.spec; do
    git -C "$srcdir" cat-file -e "$git_ref:$path" 2> /dev/null || missing="$missing $path"
done
if [ -n "$missing" ]; then
    cat >&2 <<EOF
$0: $git_ref does not contain:$missing

The containers build a source package exported from Git, not the working tree,
so the packaging has to be committed first. Commit it, or pass -r with a
revision that has it.
EOF
    exit 1
fi

# Build context. The images need the build dependency lists and the helper scripts, and nothing else:
# a context of the whole repository would send the target directories and the vendored tree to the
# container daemon on every build. The layout inside it mirrors the repository, so the Dockerfiles
# can also be used by hand with the repository itself as the context.
#
# The dependency lists come from the revision being built, since they describe the source package the
# containers are about to build. The helper scripts come from the working tree, because they are the
# driver rather than a part of the package, and this script is being run from there as well.
context=$(mktemp -d)
trap 'rm -rf -- "$context"' EXIT INT HUP TERM
mkdir -p -- "$context/debian" "$context/packaging/rpm" "$context/packaging/docker"
git -C "$srcdir" show "$git_ref:debian/control" > "$context/debian/control"
git -C "$srcdir" show "$git_ref:packaging/rpm/intel-crashlog.spec" \
    > "$context/packaging/rpm/intel-crashlog.spec"
for script in make-source.sh build-deb.sh build-rpm.sh; do
    cp -- "$srcdir/packaging/docker/$script" "$context/packaging/docker/$script"
done

dockerfile_dir="$srcdir/packaging/docker"
host_uid=$(id -u)
host_gid=$(id -g)
results=
failures=0

record() {
    results="$results
  $1"
}

echo "Repository:  $srcdir"
echo "Revision:    $git_ref ($(git -C "$srcdir" rev-parse --short "$git_ref^{commit}"))"
echo "Output:      $output_dir"
echo "Targets:     $targets"
echo "UEFI:        $([ "$with_efi" = 1 ] && echo yes || echo no)"
echo

# Source packages. The repository is mounted read only: the container clones it, so the working tree
# of the host is never written to.
if [ "$skip_source" = 1 ]; then
    if [ ! -d "$output_dir/source" ]; then
        echo "$0: --skip-source was given but $output_dir/source does not exist" >&2
        exit 1
    fi
    echo "Reusing the source packages in $output_dir/source"
else
    echo "=== Source packages"
    "$docker" build \
        -f "$dockerfile_dir/Dockerfile.source" \
        -t "$image_prefix-source" \
        "$context"
    mkdir -p -- "$output_dir/source"
    "$docker" run --rm \
        -v "$srcdir:/src:ro" \
        -v "$output_dir/source:/out" \
        -e GIT_REF="$git_ref" \
        -e HOST_UID="$host_uid" \
        -e HOST_GID="$host_gid" \
        "$image_prefix-source"
    record "source: ok"
fi

for target in $targets; do
    echo
    echo "=== $target"
    if ! "$docker" build \
        --build-arg "WITH_EFI=$with_efi" \
        -f "$dockerfile_dir/Dockerfile.$target" \
        -t "$image_prefix-$target" \
        "$context"; then
        record "$target: the image could not be built"
        failures=$((failures + 1))
        continue
    fi

    # The package build runs without network access, which is what the vendored dependencies are
    # for. The UEFI application is the exception: its toolchain is downloaded by rustup during the
    # build, so that case gets the default network.
    network=--network=none
    if [ "$with_efi" = 1 ]; then
        network=
    fi

    mkdir -p -- "$output_dir/$target"
    status=0
    # shellcheck disable=SC2086  # $network is either one option or nothing at all.
    "$docker" run --rm $network \
        -v "$output_dir/source:/in:ro" \
        -v "$output_dir/$target:/out" \
        -e WITH_EFI="$with_efi" \
        -e RUN_LINT="$run_lint" \
        -e HOST_UID="$host_uid" \
        -e HOST_GID="$host_gid" \
        "$image_prefix-$target" || status=$?

    case "$status" in
        0) record "$target: ok" ;;
        3)
            record "$target: built, but the linter reported problems"
            failures=$((failures + 1))
            ;;
        *)
            record "$target: the build failed (exit $status)"
            failures=$((failures + 1))
            ;;
    esac
done

echo
echo "Summary:$results"
echo
echo "Artefacts in $output_dir"

if [ "$failures" -gt 0 ]; then
    exit 1
fi
