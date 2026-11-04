#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This build requires macOS + Xcode; use the included GitHub Actions workflow.' >&2
  exit 1
fi
mkdir -p build artifacts
python3 Scripts/generate_project.py
swiftc App/HeadphoneProtocol.swift Tests/main.swift -o build/protocol-tests
build/protocol-tests
xcodebuild -version
xcodebuild -project SvanarControl.xcodeproj -scheme SvanarControl \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee build/xcodebuild.log
app='build/DerivedData/Build/Products/Release-iphoneos/SvanarControl.app'
test -f "$app/SvanarControl"
/usr/bin/lipo -verify_arch arm64 "$app/SvanarControl"
/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$app/Info.plist" | grep -qx APPL
python3 Scripts/package_ipa.py "$app" artifacts/SvanarControl-unsigned.ipa
shasum -a 256 artifacts/SvanarControl-unsigned.ipa > artifacts/SHA256SUMS.txt
printf '%s\n' 'Compiled iOS arm64 IPA (unsigned). Sign before installation; not a simulator build.' > artifacts/BUILD-STATUS.txt
echo 'Output: artifacts/SvanarControl-unsigned.ipa'
