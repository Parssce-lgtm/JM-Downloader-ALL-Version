#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodebuild >/dev/null || { echo "Requires macOS and Xcode 26+"; exit 1; }
mkdir -p build
trap 'xcrun xcresulttool export attachments --path build/Tests.xcresult --output-path build/screenshots || true' EXIT
DEVICE=${JM_SIMULATOR_ID:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); names=[x for k,v in d["devices"].items() if "iOS-26" in k for x in v if x["name"]=="iPhone 17 Pro Max"]; assert names,"iPhone 17 Pro Max iOS 26 simulator unavailable"; print(names[0]["udid"])')}
xcodebuild test -project JMDownloader.xcodeproj -scheme JMDownloader \
  -destination "platform=iOS Simulator,id=$DEVICE" -parallel-testing-enabled NO \
  -derivedDataPath build/DerivedData -resultBundlePath build/Tests.xcresult CODE_SIGNING_ALLOWED=NO
