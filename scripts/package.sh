#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) Release Looper.app, signs it ad hoc and zips it
# into dist/, for copying between the user's Macs. No App Store, sandbox or
# notarisation (personal use, see docs/plans/looper-spec.md).
#
# Usage: scripts/package.sh
#
# On the receiving Mac, unzip, move Looper.app to /Applications, then clear the
# download quarantine once:
#   xattr -dr com.apple.quarantine /Applications/Looper.app

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/Looper.app"

echo "Building universal Release app…"
xcodebuild build \
    -project Looper.xcodeproj \
    -scheme Looper \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Looper")"
echo "Architectures: $ARCHS"
if [[ "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ]]; then
    echo "error: expected a universal binary (arm64 + x86_64)" >&2
    exit 1
fi

# Ad hoc signature: Apple Silicon refuses to run unsigned code; ad hoc is enough for
# personal use.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
mkdir -p dist
ZIP="dist/Looper-$VERSION-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP"
