#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodebuild >/dev/null || { echo "Requires macOS and Xcode 26+"; exit 1; }
mkdir -p build
xcodebuild -project JMDownloader.xcodeproj -scheme JMDownloader -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/Device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p build/Payload
ditto build/Device/Build/Products/Release-iphoneos/JMDownloader.app build/Payload/JMDownloader.app
(cd build && /usr/bin/zip -qry JM-downloader-unsigned.ipa Payload)
