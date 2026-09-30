#!/bin/bash
# Builds build/LogMac.app from the SwiftPM package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/LogMac.app
# Quit the running copy so a following `open` launches the new build.
pkill -x LogMac || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LogMac "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
