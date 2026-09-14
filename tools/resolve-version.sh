#!/usr/bin/env bash
# Which diffTerm version should we build?
#
#   tools/resolve-version.sh           the VERSION line of the Makefile
#   tools/resolve-version.sh 2.1       that version, validated (leading v tolerated)
#
# Echoes the version on stdout and NOTHING else -- CI captures it. Progress
# and errors go to stderr.
#
# Runs on Linux, before the macOS job exists. See .ci/CONTRACT.md.
#
# diffTerm is built from this repository rather than packaged from an upstream
# release, so "the current version" is simply what the Makefile says. A tag
# push passes the tag through the workflow's version input, which lands here
# as $1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="${1:-}"
VERSION="${VERSION#v}"

if [ -z "$VERSION" ]; then
    VERSION="$(awk '/^VERSION/ { print $NF; exit }' "$ROOT/Makefile")"
    echo "==> Makefile says $VERSION" >&2
fi

printf '%s' "$VERSION" | grep -qE '^[0-9]+(\.[0-9]+)*$' \
    || { echo "not a version: '$VERSION'" >&2; exit 1; }

echo "$VERSION"
