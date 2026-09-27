#!/bin/sh
# Builds build/release/Crumbs-<version>.zip.
#
#   scripts/release.sh                      ad-hoc signed (users need "Open Anyway")
#   scripts/release.sh --notarize PROFILE   Developer ID signed, notarized, stapled
#
# PROFILE is a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials PROFILE --apple-id you@example.com --team-id TEAMID
# and needs a "Developer ID Application" certificate in the login keychain.
set -eu
cd "$(dirname "$0")/.."

TEAM_ID=${TEAM_ID:-6GU9GRW2YY}
PROFILE=""
if [ "${1:-}" = "--notarize" ]; then PROFILE=${2:?notarytool keychain profile name}; fi

version=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml)
out=build/release
rm -rf "$out" build/Crumbs.xcarchive
mkdir -p "$out"
xcodegen generate --quiet
swift test

if [ -n "$PROFILE" ]; then
  xcodebuild archive -project Crumbs.xcodeproj -scheme Crumbs -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath build/Crumbs.xcarchive \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
    OTHER_CODE_SIGN_FLAGS=--timestamp | grep -E "error|ARCHIVE"
  app=build/Crumbs.xcarchive/Products/Applications/Crumbs.app
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$app"
  rm "$out/notarize.zip"
else
  xcodebuild build -project Crumbs.xcodeproj -scheme Crumbs -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData | grep -E "error|BUILD"
  app=build/DerivedData/Build/Products/Release/Crumbs.app
fi

codesign --verify --deep --strict "$app"
zip="$out/Crumbs-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
(cd "$out" && shasum -a 256 "Crumbs-$version.zip") | tee "$zip.sha256"| tee "$zip.sha256"
