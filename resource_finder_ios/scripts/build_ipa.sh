#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodebuild -version | tee build/xcode-version.txt
python3 scripts/prepare_assets.py
xcodegen generate
xcodebuild -project ResourceFinder.xcodeproj -scheme ResourceFinder -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Device.xcarchive \
  -derivedDataPath build/Device CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  archive 2>&1 | tee build/device-build.log
python3 scripts/package_ipa.py
