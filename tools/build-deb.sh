#!/usr/bin/env bash
# Assemble the .deb from the payload build-payload.sh staged.
#
#   tools/build-deb.sh [revision]
#
# The version comes from packaging/payload/PAYLOAD.version, which
# build-payload.sh writes, so the two cannot disagree about what was built.
# Runs on Linux and needs nothing but dpkg-deb: the payload crossed an
# artifact boundary to get here and is already built and signed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/packaging/payload"
OUT="${OUT:-$ROOT/repo/debs}"

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
mkdir -p "$STAGING/DEBIAN" \
    "$STAGING/var/jb/Applications" \
    "$STAGING/var/jb/Library/LaunchDaemons"

cp -R "$PAYLOAD/diffTerm.app" "$STAGING/var/jb/Applications/diffTerm.app"
cp "$PAYLOAD/dev.diffterm.sessiond.plist" "$STAGING/var/jb/Library/LaunchDaemons/"

# The artifact boundary does not preserve POSIX permissions: upload-artifact
# zips the payload and every file comes back 0644 no matter how it was
# built. A terminal nobody can exec is not a terminal, so modes are set
# here, explicitly, and then verified — a wrong mode fails this build
# instead of failing on someone's home screen.
APP_STAGING="$STAGING/var/jb/Applications/diffTerm.app"
chmod 755 "$APP_STAGING/diffTerm" "$APP_STAGING/sessiond"
find "$APP_STAGING/helpers" -type f -exec chmod 755 {} +
for bin in diffTerm sessiond helpers/pbcopy helpers/pbpaste; do
    [ -x "$APP_STAGING/$bin" ] \
        || { echo "not executable after staging: $bin"; exit 1; }
done

# Same layout as the app bundle, so deleting the package takes its daemon
# config with it and installing registers it (postinst).
sed -e "s|@VERSION@|$PKGVER|g" \
    -e "s|@REPO@|$GH_REPO|g" \
    -e "s|@PAGES@|$GH_PAGES|g" \
    "$ROOT/packaging/DEBIAN/control.in" > "$STAGING/DEBIAN/control"
cp "$ROOT/packaging/DEBIAN/postinst" "$ROOT/packaging/DEBIAN/prerm" "$STAGING/DEBIAN/"
chmod 755 "$STAGING/DEBIAN/postinst" "$STAGING/DEBIAN/prerm"

mkdir -p "$OUT"
# --root-owner-group: built by a CI user, installed as root.
dpkg-deb --root-owner-group -Zgzip -b "$STAGING" \
    "$OUT/dev.diffterm.app_${PKGVER}_iphoneos-arm64.deb"
echo "==> built dev.diffterm.app_${PKGVER}_iphoneos-arm64.deb"
