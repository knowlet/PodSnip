#!/bin/bash
# Only uses a freshly-created simulator and authored temporary stores.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "NOT RUN: native persistence migration requires macOS and Xcode 27+." >&2
  exit 2
fi
if [[ $# -ne 2 ]]; then
  echo "Usage: bash $0 <installed-iOS-runtime-ID> <installed-device-type-ID>" >&2
  echo "Inspect IDs with: xcrun simctl list runtimes; xcrun simctl list devicetypes" >&2
  exit 2
fi
runtime="$1"
device_type="$2"
case "$runtime" in
  com.apple.CoreSimulator.SimRuntime.iOS-*) ;;
  *) echo "Only an installed iOS runtime is accepted." >&2; exit 2 ;;
esac
xcodebuild -version
xcrun swift --version
xcode_major="$(xcodebuild -version | awk '/^Xcode / {split($2, v, "."); print v[1]}')"
if [[ ! "$xcode_major" =~ ^[0-9]+$ ]] || (( xcode_major < 27 )); then
  echo "NOT RUN: the full app requires the Xcode 27+ SDK." >&2
  exit 2
fi
python3 scripts/check_legacy_schema.py
xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtime = sys.argv[1]
items = json.load(sys.stdin)["runtimes"]
if not any(r["identifier"] == runtime and r.get("isAvailable") for r in items):
    sys.exit("Requested runtime is not installed/available; nothing will be downloaded.")
' "$runtime"

# Create instead of reusing a supplied/booted device: even the hosted app's
# default store, settings and Keychain must be disposable and empty.
device=""
cleanup() {
  if [[ -n "$device" ]]; then
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
device="$(xcrun simctl create "PodSnip-Migration-$(uuidgen)" "$device_type" "$runtime")"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
mkdir -p .build
output="$(mktemp -d "$PWD/.build/migration-XXXXXX")"
git rev-parse HEAD > "$output/commit.txt"
git diff --stat > "$output/working-tree-diff.txt"
printf '%s\n' "$runtime" "$device_type" "$device" > "$output/destination.txt"
xcodebuild -project PodSnip.xcodeproj -scheme PodSnip \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$device" \
  -destination-timeout 60 -derivedDataPath "$output/DerivedData" \
  -resultBundlePath "$output/Migration.xcresult" \
  -only-testing:PodSnipTests/PersistenceMigrationTests \
  -parallel-testing-enabled NO -jobs 2 CODE_SIGNING_ALLOWED=NO test \
  2>&1 | tee "$output/xcodebuild.log"
echo "Native result bundle: $output/Migration.xcresult"
