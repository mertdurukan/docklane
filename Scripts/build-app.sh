#!/bin/bash
# Builds Docklane.app.
#
#   Scripts/build-app.sh                  build, sign, install to /Applications and relaunch
#   UNIVERSAL=1 Scripts/build-app.sh      Apple Silicon + Intel binary
#   INSTALL=0 Scripts/build-app.sh        only produce dist/Docklane.app
#   ZIP=1 INSTALL=0 Scripts/build-app.sh  also produce dist/Docklane.zip (for releases)
#   SIGN_IDENTITY="My Cert" ...           code-signing identity (see README)
#   NOTARIZE=1 ...                        notarize and staple (needs a Developer ID Application
#                                         identity and a notarytool keychain profile, see README)
#   VERSION=0.2.0 BUILD=3 ...             version numbers
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Docklane"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
UNIVERSAL="${UNIVERSAL:-0}"
INSTALL="${INSTALL:-1}"
ZIP="${ZIP:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Docklane Self-Signed}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-docklane}"

if [ "$UNIVERSAL" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN_DIR=".build/apple/Products/Release"
else
    swift build -c release
    BIN_DIR=".build/release"
fi

BUNDLE="dist/$APP.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
sed -e "s/<string>VERSION<\/string>/<string>$VERSION<\/string>/" \
    -e "s/<string>BUILD<\/string>/<string>$BUILD<\/string>/" \
    Resources/Info.plist > "$BUNDLE/Contents/Info.plist"

# Localizations: compile the String Catalogs (UI text and Info.plist prompts) into the main
# bundle (en is the source language).
LOC_TMP="$(mktemp -d)"
xcrun xcstringstool compile Localization/Localizable.xcstrings --output-directory "$LOC_TMP" >/dev/null
xcrun xcstringstool compile Localization/InfoPlist.xcstrings --output-directory "$LOC_TMP" >/dev/null
cp -R "$LOC_TMP"/*.lproj "$BUNDLE/Contents/Resources/"
mkdir -p "$BUNDLE/Contents/Resources/en.lproj"
rm -rf "$LOC_TMP"

# Sign with a stable identity when available, so macOS keeps the Accessibility and Screen
# Recording permissions across rebuilds. Otherwise fall back to an ad-hoc signature.
# The hardened runtime is required for notarization; Developer ID signatures get a timestamp.
# SIGN_IDENTITY may be a prefix such as "Developer ID Application".
if security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY"; then
    TIMESTAMP=()
    [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]] && TIMESTAMP=(--timestamp)
    codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --sign "$SIGN_IDENTITY" "$BUNDLE"
    echo "Signed with \"$SIGN_IDENTITY\""
else
    [ "$NOTARIZE" = "1" ] && { echo "NOTARIZE=1 needs the \"$SIGN_IDENTITY\" identity" >&2; exit 1; }
    codesign --force --sign - "$BUNDLE"
    echo "Ad-hoc signed (permissions must be granted again after each rebuild)"
fi

if [ "$NOTARIZE" = "1" ]; then
    ditto -c -k --keepParent "$BUNDLE" "dist/$APP-notarize.zip"
    xcrun notarytool submit "dist/$APP-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "dist/$APP-notarize.zip"
    xcrun stapler staple "$BUNDLE"
    spctl --assess --type execute --verbose "$BUNDLE"
fi

if [ "$ZIP" = "1" ]; then
    ditto -c -k --keepParent "$BUNDLE" "dist/$APP.zip"
    echo "Wrote dist/$APP.zip"
fi

if [ "$INSTALL" != "1" ]; then
    echo "Built $BUNDLE"
    exit 0
fi

if pgrep -x "$APP" >/dev/null; then
    osascript -e "quit app \"$APP\"" >/dev/null 2>&1 || pkill -x "$APP" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP" >/dev/null || break; sleep 0.2; done
fi
rm -rf "/Applications/$APP.app"
cp -R "$BUNDLE" "/Applications/$APP.app"
open "/Applications/$APP.app"
echo "Installed /Applications/$APP.app"
