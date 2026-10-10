#!/bin/bash
# Builds a notarized universal Docklane.zip and attaches it to an existing GitHub release,
# replacing the ad-hoc signed zip that CI uploaded for the tag.
#
#   Scripts/release-notarized.sh 0.1.0
#
# Needs a "Developer ID Application" identity in the keychain and a notarytool keychain
# profile named "docklane" (or NOTARY_PROFILE); see README → Releasing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release-notarized.sh <version>}"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "No tag v$VERSION" >&2; exit 1; }
# The app's contents must match the tag; scripts and docs may be newer.
git diff --quiet "v$VERSION" -- Sources Resources Localization Package.swift \
    && git diff --quiet -- Sources Resources Localization Package.swift \
    || { echo "The app's sources differ from v$VERSION; check out the tag first" >&2; exit 1; }

UNIVERSAL=1 INSTALL=0 ZIP=1 NOTARIZE=1 SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}" \
    VERSION="$VERSION" BUILD="${BUILD:-$(git rev-list --count HEAD)}" Scripts/build-app.sh

gh release upload "v$VERSION" dist/Docklane.zip --clobber
echo "Uploaded the notarized Docklane.zip to v$VERSION"
