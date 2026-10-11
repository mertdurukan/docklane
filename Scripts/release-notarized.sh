#!/bin/bash
# Publishes a Docklane release from this Mac, under your own GitHub account:
#
#   Scripts/release-notarized.sh 0.2.0             checks, builds, notarizes, creates a DRAFT
#                                                  release and verifies the zip downloaded from it
#   PUBLISH=1 Scripts/release-notarized.sh 0.2.0   … and publishes it once verified
#   DRY_RUN=1 Scripts/release-notarized.sh 0.2.0   only the checks
#
# Checks first: the tag v<version> exists, is annotated, matches the app's sources and is on
# origin/main; CHANGELOG.md has a "## [<version>]" section; a Developer ID Application
# certificate valid for 30 more days; notarytool credentials that work (an unaccepted Apple
# agreement shows up here). Needs the "docklane" notarytool keychain profile (or
# NOTARY_PROFILE); see README → Releasing. An existing release keeps its notes and gets the
# new zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release-notarized.sh <version>}"
TAG="v$VERSION"
NOTARY_PROFILE="${NOTARY_PROFILE:-docklane}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
fail() { echo "✗ $*" >&2; exit 1; }
ok() { echo "✓ $*"; }

# --- Checks ---------------------------------------------------------------------------------
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "No tag $TAG (git tag -a $TAG -m \"Docklane $VERSION\")"
[ "$(git cat-file -t "$TAG")" = "tag" ] || fail "$TAG is a lightweight tag; use git tag -a"
# The app's contents must match the tag; scripts and docs may be newer.
git diff --quiet "$TAG" -- Sources Resources Localization Package.swift \
    && git diff --quiet -- Sources Resources Localization Package.swift \
    || fail "The app's sources differ from $TAG; check out the tag first"
ok "Tag $TAG matches the sources"
git fetch --quiet origin main
git merge-base --is-ancestor "$TAG^{commit}" origin/main || fail "$TAG is not on origin/main; push main first"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || fail "$TAG is not on GitHub: git push origin $TAG"
ok "$TAG is on origin/main and pushed"

NOTES="$(mktemp -t docklane-notes)"
awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { found = 1; next }
    found && (/^## \[/ || /^\[/) { exit }
    found { print }
' CHANGELOG.md > "$NOTES"
[ -s "$NOTES" ] || fail "CHANGELOG.md has no \"## [$VERSION]\" section"
ok "Changelog section for $VERSION"

CERT="$(security find-certificate -c "$IDENTITY" -p 2>/dev/null || true)"
[ -n "$CERT" ] || fail "No \"$IDENTITY\" certificate in the keychain"
EXPIRY="$(openssl x509 -noout -enddate <<<"$CERT" | cut -d= -f2)"
openssl x509 -noout -checkend $((30 * 24 * 3600)) <<<"$CERT" >/dev/null \
    || fail "The Developer ID certificate expires $EXPIRY (under 30 days); renew it first"
ok "Developer ID certificate valid until $EXPIRY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool can't sign in with profile \"$NOTARY_PROFILE\" (expired password or an Apple agreement to accept?)"
ok "notarytool credentials work"

if [ "${DRY_RUN:-0}" = "1" ]; then echo "Dry run: stopping before the build"; exit 0; fi

# --- Build, notarize, release ---------------------------------------------------------------
UNIVERSAL=1 INSTALL=0 ZIP=1 NOTARIZE=1 SIGN_IDENTITY="$IDENTITY" \
    VERSION="$VERSION" BUILD="${BUILD:-$(git rev-list --count "$TAG")}" Scripts/build-app.sh
SHA="$(shasum -a 256 dist/Docklane.zip | cut -d' ' -f1)"
ok "Docklane.zip SHA-256 $SHA"

if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" dist/Docklane.zip --clobber
    ok "Replaced Docklane.zip on the existing $TAG release"
else
    cat docs/release-install.md >> "$NOTES"
    printf '\n**SHA-256** of Docklane.zip: `%s`\n' "$SHA" >> "$NOTES"
    gh release create "$TAG" dist/Docklane.zip --draft --verify-tag \
        --title "Docklane $VERSION" --notes-file "$NOTES"
    ok "Created a draft release $TAG"
fi

# --- Verify what people will download ---------------------------------------------------------
CHECK="$(mktemp -d -t docklane-release)"
gh release download "$TAG" --pattern Docklane.zip --dir "$CHECK"
[ "$(shasum -a 256 "$CHECK/Docklane.zip" | cut -d' ' -f1)" = "$SHA" ] || fail "The uploaded zip differs from dist/Docklane.zip"
ditto -x -k "$CHECK/Docklane.zip" "$CHECK"
APP="$CHECK/Docklane.app"
spctl --assess --type execute "$APP" || fail "Gatekeeper rejects the downloaded app"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Docklane")"
[[ "$ARCHS" == *x86_64* && "$ARCHS" == *arm64* ]] || fail "Not universal: $ARCHS"
SHOWN="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$SHOWN" = "$VERSION" ] || fail "The app says version $SHOWN"
ok "Downloaded zip: notarized, $ARCHS, version $SHOWN"

if [ "${PUBLISH:-0}" = "1" ]; then
    gh release edit "$TAG" --draft=false
    ok "Published $TAG"
else
    echo "The release is still a draft. Publish it with: gh release edit $TAG --draft=false"
fi
