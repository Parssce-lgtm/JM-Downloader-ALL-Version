#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodebuild -version
xcrun simctl list runtimes
MAJOR=${JM_TEST_OS:?Expected iOS major version}
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; m=sys.argv[1]; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-"+m+"-")]; assert r,"Requested runtime unavailable"; print(sorted(r,key=lambda x:tuple(map(int,x["version"].split("."))))[-1]["identifier"])' "$MAJOR")
DEVICE=$(xcrun simctl create "JM compatibility iOS $MAJOR" "${JM_DEVICE_TYPE:?Expected device type}" "$RUNTIME")
export_results() {
  status=$?
  trap - EXIT
  if [ -d /Applications/Xcode_16.2.app ]; then export DEVELOPER_DIR=/Applications/Xcode_16.2.app/Contents/Developer; fi
  if [ -d build/Compatibility.xcresult ] && xcrun xcresulttool export attachments --help >/dev/null 2>&1; then
    xcrun xcresulttool export attachments --path build/Compatibility.xcresult --output-path build/screenshots || true
  else
    CONTAINER=$(xcrun simctl get_app_container "$DEVICE" app.jmdownloader.jmdownloaderuitests.xctrunner data || true)
    mkdir -p build/screenshots
    if [ -d "$CONTAINER/Documents/compatibility-shots" ]; then cp "$CONTAINER/Documents/compatibility-shots/"*.png build/screenshots/; fi
  fi
  exit "$status"
}
trap export_results EXIT
xcodebuild test -project JMDownloader.xcodeproj -scheme JMDownloader \
  -destination "platform=iOS Simulator,id=$DEVICE" -parallel-testing-enabled NO \
  -only-testing:JMDownloaderTests -only-testing:JMDownloaderUITests/CompatibilityUITests \
  -derivedDataPath build/CompatibilityDerivedData -resultBundlePath build/Compatibility.xcresult CODE_SIGNING_ALLOWED=NO
