#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodebuild -version | tee build/xcode-version.txt
xcodegen generate
task_simulator_id="$(xcrun simctl list devices available -j | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(x["udid"] for group in d["devices"].values() for x in group if x["name"].startswith("iPhone")))')"
task_test_status=0
set --
if [ "${RF_UNIT_DIAGNOSTICS:-false}" = "true" ]; then
  set -- -only-testing:ResourceFinderTests
  printf '%s\n' '{"mode":"unit-diagnostics","fullAcceptance":false}' > build/validation-mode.json
fi
xcodebuild -project ResourceFinder.xcodeproj -scheme ResourceFinder -configuration Debug \
  -destination "platform=iOS Simulator,id=$task_simulator_id" \
  -derivedDataPath build/DerivedData -resultBundlePath build/Tests.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 180 "$@" test 2>&1 | tee build/test.log || task_test_status=$?
python3 - <<'PY_CRASH'
from pathlib import Path
import shutil
root=Path.home()/'Library/Logs/DiagnosticReports'
dest=Path('build/crashes'); dest.mkdir(exist_ok=True)
for path in root.rglob('ResourceFinder*.ips'):
    shutil.copy2(path,dest/path.name)
PY_CRASH
if [ -d build/Tests.xcresult ]; then
  xcrun xcresulttool export attachments --path build/Tests.xcresult --output-path build/screenshots || true
  xcrun xcresulttool get test-results summary --path build/Tests.xcresult --format json > build/test-summary.json || true
fi
if [ -d build/DerivedData/Build/Products/Debug-iphonesimulator/ResourceFinder.app ]; then
  codesign -d --entitlements :- build/DerivedData/Build/Products/Debug-iphonesimulator/ResourceFinder.app 2>build/simulator-signing.txt | tee build/simulator-entitlements.plist || true
fi
if [ "$task_test_status" -ne 0 ]; then exit "$task_test_status"; fi
if [ "${RF_UNIT_DIAGNOSTICS:-false}" = "true" ]; then exit 0; fi
ditto -c -k --sequesterRsrc --keepParent build/DerivedData/Build/Products/Debug-iphonesimulator/ResourceFinder.app build/Resource-Finder-iOS-0.4-Simulator.zip
shasum -a 256 build/Resource-Finder-iOS-0.4-Simulator.zip > build/Resource-Finder-iOS-0.4-Simulator.sha256
