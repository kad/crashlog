#!/bin/sh
# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: MIT
#
# Lists the Rust crates that end up in the packages built from this repository, together with their
# version, the authors they declare and their license expression. The output keeps the licensing
# information of the vendored dependencies up to date in debian/copyright and in the Provides of
# packaging/rpm/intel-crashlog.spec, as both distributions require for bundled code.

set -eu

usage() {
    cat <<EOF
Usage: $0 [-f FORMAT]

Options:
  -f FORMAT  One of:
               text  crate, version and license expression, per package
                     (default)
               rpm   the bundled crate Provides expected by the Fedora
                     packaging guidelines, per subpackage
               dep5  the Files stanzas covering vendor/* expected by the
                     Debian copyright format
               manifest
                     one line per vendored crate, for the licensing artefacts
                     that RPM packages ship as %license
  -h         Show this help message

The text and rpm formats describe the crates whose code is linked into the
binaries, resolved per package and per target, and require Cargo. The dep5 and
manifest formats describe every directory of the vendored tree, because a
source package and the report shipped with it have to account for what is
actually there, and therefore require vendor/ to be present instead.

Requires python3. The dep5 format additionally needs tomllib, so Python 3.11 or
later; the manifest format reads the few fields it needs itself and works with
any Python 3, because it runs inside RPM build roots that predate tomllib. Runs
offline once packaging/vendor.sh has been run.
EOF
}

format=text

while getopts ':f:h' opt; do
    case "$opt" in
        f) format=$OPTARG ;;
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

case "$format" in
    text | rpm | dep5 | manifest) ;;
    *)
        echo "$0: unknown format '$format'" >&2
        exit 1
        ;;
esac

srcdir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if ! command -v python3 >/dev/null 2>&1; then
    echo "$0: python3 is not installed" >&2
    exit 1
fi

case "$format" in
    text | rpm)
        if ! command -v cargo >/dev/null 2>&1; then
            echo "$0: cargo is not installed" >&2
            exit 1
        fi
        ;;
    dep5 | manifest)
        if [ ! -d "$srcdir/vendor" ]; then
            echo "$0: $srcdir/vendor does not exist; run packaging/vendor.sh first" >&2
            exit 1
        fi
        ;;
esac

# The licensing artefacts that the RPM packaging ships as %license. On Fedora they come from the
# cargo-rpm-macros package, which openSUSE does not have, so this format stands in for
# %cargo_vendor_manifest and %cargo_license there. It reports the vendored tree rather than the
# dependency closure of one package, which is also what those macros do, and it deliberately parses
# the handful of fields it needs out of the manifests instead of using tomllib: the format has to
# work in a build root where python3 is whatever the distribution ships.
if [ "$format" = manifest ]; then
    python3 - "$srcdir/vendor" <<'PYTHON'
import os
import sys

vendor = sys.argv[1]


def package_fields(path):
    """The scalar fields of the [package] table of a manifest.

    The manifests in a vendored tree are the normalised ones cargo publishes, where every field of
    that table is on a line of its own, so scanning is enough and no TOML parser is needed. Only
    single line string values are recognised, which is all that is read here.
    """
    fields = {}
    in_package = False
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if line.startswith("["):
                # Nested tables such as [package.metadata.docs.rs] are not the [package] table.
                in_package = line in ("[package]", "[project]")
                continue
            if not in_package or "=" not in line:
                continue
            key, _, value = line.partition("=")
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                fields[key.strip()] = value[1:-1]
    return fields


rows = []
for name in sorted(os.listdir(vendor)):
    manifest = os.path.join(vendor, name, "Cargo.toml")
    if not os.path.isfile(manifest):
        continue
    fields = package_fields(manifest)
    crate = fields.get("name", name)
    version = fields.get("version", "unknown")
    if "license" in fields:
        license = fields["license"]
    elif "license-file" in fields:
        license = "see vendor/%s/%s" % (name, fields["license-file"])
    else:
        license = "see the license files under vendor/%s/" % name
    rows.append((crate, version, license, name))

print("# Bundled Rust crates, generated by packaging/vendor-licenses.sh -f manifest.")
print("# One line per directory of the vendored tree that is shipped in the source package:")
print("# crate, version, the license expression the crate declares, and the directory it was")
print("# vendored into. This covers the whole tree, so crates that are only compiled at build time")
print("# or that apply to another platform are listed as well. The expressions are the ones the")
print("# crates state in their own Cargo.toml; the license files under vendor/<crate>/ are the")
print("# authoritative statement.")
print("#")
print("# %d bundled crates, %d distinct license expressions:"
      % (len(rows), len({row[2] for row in rows})))
for license in sorted({row[2] for row in rows}):
    print("#   %s" % license)
print()
for crate, version, license, name in rows:
    suffix = "" if name == "%s-%s" % (crate, version) else " [vendor/%s]" % name
    print("%s %s: %s%s" % (crate, version, license, suffix))
PYTHON

    exit 0
fi

# The Debian copyright file describes the source package as it is shipped, so every directory of the
# vendored tree has to be covered, not only the crates whose code is linked into the binaries: the
# build only dependencies and the ones that apply to another platform are in the tarball as well, and
# some of them carry terms that appear nowhere else, such as the MPL-2.0 of cbindgen. The vendored
# tree is therefore read directly instead of being derived from a resolve graph, which also gets the
# directory names right where Cargo had to disambiguate two versions of the same crate.
if [ "$format" = dep5 ]; then
    python3 - "$srcdir/vendor" <<'PYTHON'
import os
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(
        "vendor-licenses: the dep5 format needs tomllib, which comes with Python 3.11 and later"
    )

vendor = sys.argv[1]


def dep5_atoms(expression):
    """The individual license short names of an SPDX expression, in the copyright format syntax."""
    # Old crates use a slash as the alternative separator, and the short names of the copyright
    # format carry no parentheses and are joined by lower case operators. A WITH clause stays part
    # of the name it qualifies, since that is what the exception applies to.
    words = expression.replace("/", " OR ").replace("(", " ").replace(")", " ").split()
    atoms = [[]]
    for word in words:
        if word.upper() in ("OR", "AND"):
            atoms.append([])
        elif word.upper() == "WITH":
            atoms[-1].append("with")
        else:
            atoms[-1].append(word)
    return [" ".join(atom) for atom in atoms if atom]


def dep5_license(expression):
    """The license field of a crate, in the syntax of the Debian copyright format."""
    words = expression.replace("/", " OR ").replace("(", " ").replace(")", " ").split()
    return " ".join(
        word.lower() if word.upper() in ("OR", "AND", "WITH") else word for word in words
    )


# Crates that declare the same terms and the same authors share a stanza, which keeps the generated
# part of debian/copyright readable. A crate that needs to be looked at by hand is kept in a stanza
# of its own, so that the note above it applies to one directory only.
entries = {}
notes = {}
for name in sorted(os.listdir(vendor)):
    manifest = os.path.join(vendor, name, "Cargo.toml")
    if not os.path.isfile(manifest):
        continue
    with open(manifest, "rb") as stream:
        package = tomllib.load(stream).get("package", {})
    authors = tuple(package.get("authors") or ())
    expression = package.get("license")
    key = (expression or f"FIXME {name}", authors)
    if not expression:
        # A few crates state no expression at all, only a file that has to be read by hand.
        location = package.get("license-file")
        notes[key] = (
            f"# FIXME: vendor/{name} declares no license expression, only "
            + (f"license-file = {location}" if location else "the files it ships")
        )
    elif "(" in expression or "/" in expression:
        # The copyright format has no parentheses and no slash, so the rendering below is looser
        # than what the crate states: keep the original expression next to it.
        notes[key] = f"# SPDX-License-Identifier: {expression}"
    entries.setdefault(key, []).append(name)

print("# Generated by packaging/vendor-licenses.sh -f dep5. Every directory of the vendored tree is")
print("# covered, including the crates that are only used at build time or on another platform: the")
print("# copyright file describes the source package as it is shipped, not only what is linked into")
print("# the binaries. The authors and the license expression are the ones each crate declares in")
print("# its own Cargo.toml; review them against the copyright and license files under")
print("# vendor/<crate>/, which are the authoritative statement.")

for key, names in sorted(entries.items(), key=lambda item: item[1]):
    expression, authors = key
    print()
    if key in notes:
        print(notes[key])
    print("Files:")
    for name in names:
        print(f" vendor/{name}/*")
    if authors:
        print("Copyright:")
        for author in authors:
            print(f" {author}")
    else:
        print("Copyright: FIXME: these crates record no author in their Cargo.toml")
    print("License: " + ("FIXME" if key in notes and expression.startswith("FIXME ")
                         else dep5_license(expression)))

print()
print("# Every short name used above needs a stand-alone License paragraph in debian/copyright:")
atoms = {
    atom
    for expression, _ in entries
    if not expression.startswith("FIXME ")
    for atom in dep5_atoms(expression)
}
for atom in sorted(atoms):
    print(f"#   {atom}")
PYTHON

    exit 0
fi

# Resolve against the vendored sources when they are there, the same way the package builds do, so
# that the report describes exactly what has been vendored and needs no network access.
if [ -d "$srcdir/vendor" ]; then
    tmpdir=$(mktemp -d)
    trap 'rm -rf -- "$tmpdir"' EXIT INT HUP TERM
    cat > "$tmpdir/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$srcdir/vendor"
EOF
    CARGO_HOME=$tmpdir
    CARGO_NET_OFFLINE=true
    export CARGO_HOME CARGO_NET_OFFLINE
fi

# The crates of this repository, with the target they are built for. lib/ and app/ are native
# builds; efi/ is only ever built for the UEFI target. The names are passed on to the report, in the
# same order, because each of them ends up in a different package.
crates='lib:x86_64-unknown-linux-gnu app:x86_64-unknown-linux-gnu efi:x86_64-unknown-uefi'

names=
for entry in $crates; do
    names="$names ${entry%:*}"
done

# shellcheck disable=SC2086  # $crates and $names are deliberately unquoted word lists.
for entry in $crates; do
    crate=${entry%:*}
    target=${entry#*:}
    # --filter-platform drops the dependencies that are not linked on that target, such as the
    # windows and uefi crates. The resolve graph it returns also records the kind of every edge,
    # which is what lets the report leave out the build and test only dependencies.
    cargo metadata \
        --format-version 1 \
        --all-features \
        --filter-platform "$target" \
        --manifest-path "$srcdir/$crate/Cargo.toml"
done | python3 -c '
import json
import sys

fmt = sys.argv[1]
names = sys.argv[2:]

# The crates of this repository are built into the packages, not bundled in them.
local = {"intel_crashlog", "intel_crashlog_app", "intel_crashlog_efi"}


def bundled(document):
    """The packages whose code ends up in the artefacts built from one crate of this repository."""
    resolve = document["resolve"]
    nodes = {node["id"]: node for node in resolve["nodes"]}
    packages = {package["id"]: package for package in document["packages"]}

    # Only the code reachable through regular dependencies ends up in the artefacts: build
    # dependencies, such as cbindgen, and test only ones, such as tempfile, are compiled but not
    # shipped, so they are not bundled crates as far as the packaging is concerned. Procedural
    # macro crates are part of the closure, and are reported: their terms apply to the build.
    reachable = set()
    pending = [resolve["root"]]
    while pending:
        node_id = pending.pop()
        if node_id in reachable or node_id not in nodes:
            continue
        reachable.add(node_id)
        for dep in nodes[node_id]["deps"]:
            if any(kind["kind"] is None for kind in dep["dep_kinds"]):
                pending.append(dep["pkg"])

    return {
        packages[node_id]["name"]: packages[node_id]
        for node_id in reachable
        if packages[node_id]["name"] not in local
    }


# One document per crate of this repository, concatenated on standard input and therefore in the
# order the shell loop emitted them.
decoder = json.JSONDecoder()
metadata = sys.stdin.read()
offset = 0
sections = []
while offset < len(metadata):
    document, offset = decoder.raw_decode(metadata, offset)
    while offset < len(metadata) and metadata[offset].isspace():
        offset += 1
    sections.append(bundled(document))

if len(sections) != len(names):
    sys.exit(f"vendor-licenses: expected {len(names)} reports, got {len(sections)}")

for name, section in zip(names, sections):
    print(f"# {name}")
    for crate, package in sorted(section.items()):
        version = package["version"]
        if fmt == "rpm":
            print(f"Provides:       bundled(crate({crate})) = {version}")
        else:
            license = package.get("license") or "unknown"
            print(f"{crate} {version}: {license}")
    print()
' "$format" $names
