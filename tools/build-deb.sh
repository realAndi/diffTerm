#!/usr/bin/env bash
# Assemble the .debs from the payload build-payload.sh staged.
#
#   tools/build-deb.sh [revision]
#
# The version comes from packaging/payload/PAYLOAD.version, which
# build-payload.sh writes, so the two cannot disagree about what was built.
# Runs on Linux and needs nothing but dpkg-deb: the payload crossed an
# artifact boundary to get here and is already built and signed.
#
# One payload, one package per kind of jailbreak. Nothing about where the
# bootstrap lives is compiled in -- the app finds it at launch -- so the
# packages differ only in layout and in the architecture name each
# jailbreak's package manager looks for:
#
#   rootless  iphoneos-arm64   ./var/jb/Applications   Dopamine, palera1n
#   roothide  iphoneos-arm64e  ./Applications          Serotonin + Bootstrap, Relaxin
#   rootful   iphoneos-arm     ./Applications          palera1n rootful
#
# roothide's dpkg installs ./Applications under its random root and runs the
# maintainer scripts with that root as /, so it is laid out like rootful.
# SCHEMES="rootless" builds just the one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/packaging/payload"
OUT="${OUT:-$ROOT/repo/debs}"
SCHEMES="${SCHEMES:-rootless roothide rootful}"

# The reusable workflow exports these; a local run falls back to the canonical
# values, and an empty one just drops the URL-only control fields.
GH_REPO="${GH_REPO:-realAndi/diffTerm}"
GH_PAGES="${GH_PAGES:-realandi.github.io/diffTerm}"

command -v dpkg-deb >/dev/null \
    || { echo "need dpkg-deb (apt install dpkg-dev / brew install dpkg)"; exit 1; }
[ -f "$PAYLOAD/PAYLOAD.version" ] \
    || { echo "missing packaging/payload/PAYLOAD.version -- run tools/build-payload.sh first"; exit 1; }
[ -d "$PAYLOAD/diffTerm.app" ] \
    || { echo "missing packaging/payload/diffTerm.app -- run tools/build-payload.sh first"; exit 1; }

read -r VERSION < "$PAYLOAD/PAYLOAD.version"
REV="${1:-}"
PKGVER="$VERSION${REV:+-$REV}"

# Cheap check on the binary that just crossed the artifact boundary: it is
# still an arm64 Mach-O. dyld verifies the rest (platform, signature, dylibs)
# on device; the full checks need otool, which Linux does not have.
magic=$(head -c 4 "$PAYLOAD/diffTerm.app/diffTerm" | od -An -tx1 | tr -d ' \n')
[ "$magic" = "cffaedfe" ] || { echo "diffTerm is not a Mach-O (magic $magic)"; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$OUT"

build() {
    local scheme="$1" prefix arch
    case "$scheme" in
        rootless) prefix=/var/jb; arch=iphoneos-arm64 ;;
        roothide) prefix=;        arch=iphoneos-arm64e ;;
        rootful)  prefix=;        arch=iphoneos-arm ;;
        *) echo "unknown scheme '$scheme' (rootless, roothide or rootful)"; exit 1 ;;
    esac

    local stage="$STAGING/$scheme"
    local app="$stage$prefix/Applications/diffTerm.app"
    mkdir -p "$stage/DEBIAN" "$stage$prefix/Applications"
    cp -R "$PAYLOAD/diffTerm.app" "$app"

    # The artifact boundary does not preserve POSIX permissions: upload-artifact
    # zips the payload and every file comes back 0644 no matter how it was
    # built. A terminal nobody can exec is not a terminal, so modes are set
    # here, explicitly, and then verified — a wrong mode fails this build
    # instead of failing on someone's home screen. Everything is set, not
    # just the executables: a payload built under umask 077, as on a device,
    # would otherwise install a root-owned bundle the app cannot read.
    find "$stage" -type d -exec chmod 755 {} +
    find "$stage" -type f -exec chmod 644 {} +
    chmod 755 "$app/diffTerm"
    find "$app/helpers" -type f -exec chmod 755 {} +
    for bin in diffTerm helpers/pbcopy helpers/pbpaste; do
        [ -x "$app/$bin" ] \
            || { echo "not executable after staging: $bin ($scheme)"; exit 1; }
    done

    sed -e "s|@VERSION@|$PKGVER|g" \
        -e "s|@ARCH@|$arch|g" \
        -e "s|@REPO@|$GH_REPO|g" \
        -e "s|@PAGES@|$GH_PAGES|g" \
        "$ROOT/packaging/DEBIAN/control.in" > "$stage/DEBIAN/control"
    for script in postinst prerm; do
        sed -e "s|@JB@|$prefix|g" "$ROOT/packaging/DEBIAN/$script" > "$stage/DEBIAN/$script"
        chmod 755 "$stage/DEBIAN/$script"
    done
    # A placeholder left in a script would name a path that does not exist,
    # and uicache would register nothing without saying so.
    if grep -q '@[A-Z]*@' "$stage/DEBIAN/control" "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"; then
        echo "unfilled placeholder in the $scheme package's DEBIAN files"; exit 1
    fi

    local deb="dev.diffterm.app_${PKGVER}_${arch}.deb"
    # --root-owner-group: built by a CI user, installed as root.
    dpkg-deb --root-owner-group -Zgzip -b "$stage" "$OUT/$deb"
    echo "==> built $deb ($scheme)"
}

for scheme in $SCHEMES; do
    build "$scheme"
done
