#!/usr/bin/env bash
# Build diffTerm and stage everything the package will contain.
#
#   tools/build-payload.sh <version>
#
# Runs on macOS: this is the step that needs Xcode's iPhoneOS SDK and ldid.
# The .deb itself is assembled on Linux by build-deb.sh from what lands in
# packaging/payload/ -- the artifact boundary between the two runners.
#
# The Makefile was written for on-device builds and cross-builds with Xcode
# when /var/jb is absent, which is exactly what this runner is.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: build-payload.sh <version>}"

make -C "$ROOT" clean >/dev/null
make -C "$ROOT" "build/diffTerm.app/diffTerm"

PAYLOAD="$ROOT/packaging/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
cp -R "$ROOT/build/diffTerm.app" "$PAYLOAD/diffTerm.app"
printf '%s\n' "$VERSION" > "$PAYLOAD/PAYLOAD.version"

echo "==> payload staged in packaging/payload/ ($(du -sh "$PAYLOAD" | cut -f1))"
