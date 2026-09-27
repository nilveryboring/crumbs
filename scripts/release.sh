#!/bin/sh
# Builds build/release/Crumbs-<version>.zip.
#
#   scripts/release.sh             Developer ID signed and notarized, using the
#                                  Apple account signed into Xcode (Settings →
#                                  Accounts). No passwords or keychain profiles.
#   scripts/release.sh --unsigned  ad-hoc signed; users need "Open Anyway"
set -eu
cd "$(dirname "$0")/.."

TEAM_ID=${TEAM_ID:-6GU9GRW2YY}
version=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml)
out=build/release
rm -rf "$out" build/Crumbs.xcarchive build/upload build/notarized
mkdir -p "$out"
xcodegen generate --quiet
swift test

if [ "${1:-}" = "--unsigned" ]; then
  xcodebuild build -project Crumbs.xcodeproj -scheme Crumbs -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData | grep -E "error|BUILD"
  app=build/DerivedData/Build/Products/Release/Crumbs.app
else
  options() {
    cat > "build/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>$2</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
  }
  options ExportUpload upload

  xcodebuild archive -project Crumbs.xcodeproj -scheme Crumbs -configuration Release \
    -destination "generic/platform=macOS" -archivePath build/Crumbs.xcarchive \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    -allowProvisioningUpdates | grep -E "error:|ARCHIVE"
  # Signs with the cloud-managed Developer ID certificate and submits to Apple's notary service.
  xcodebuild -exportArchive -archivePath build/Crumbs.xcarchive -exportPath build/upload \
    -exportOptionsPlist build/ExportUpload.plist -allowProvisioningUpdates | grep -E "error|EXPORT"

  echo "Waiting for notarization…"
  tries=0
  until xcodebuild -exportNotarizedApp -archivePath build/Crumbs.xcarchive -exportPath build/notarized \
      > build/notarized.log 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 90 ]; then cat build/notarized.log; exit 1; fi
    sleep 20
  done
  app=build/notarized/Crumbs.app
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

codesign --verify --deep --strict "$app"
zip="$out/Crumbs-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
(cd "$out" && shasum -a 256 "Crumbs-$version.zip") | tee "$zip.sha256"
