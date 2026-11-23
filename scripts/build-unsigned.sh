#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project NewTube.xcodeproj -scheme NewTube -configuration Release \
  -destination 'generic/platform=iOS' -sdk iphoneos -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" build

products=build/DerivedData/Build/Products/Release-iphoneos
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload" build/release
ditto "$products/NewTube.app" "$stage/Payload/NewTube.app"
app="$stage/Payload/NewTube.app"
binary="$app/NewTube"
if codesign -d "$binary" >/dev/null 2>&1; then
  codesign --remove-signature "$binary"
fi
test -x "$binary"
lipo "$binary" -verify_arch arm64
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app/Info.plist")" = iPhoneOS
test -f "$app/Browse.js"
test -f "$app/Assets.car"
test -z "$(find "$app" \( -name _CodeSignature -o -name embedded.mobileprovision \) -print)"
if codesign -d "$binary" >/dev/null 2>&1; then
  echo "Device binary still contains a code signature" >&2
  exit 1
fi
out="$PWD/build/release/NewTube-unsigned.ipa"
rm -f "$out"
(cd "$stage" && /usr/bin/zip -qry "$out" Payload)
unzip -tq "$out"
(cd build/release && shasum -a 256 NewTube-unsigned.ipa > SHA256SUMS.txt)
