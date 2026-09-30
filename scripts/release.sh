#!/bin/bash
# Builds build/LogMac-<version>.zip for a GitHub release and prints its SHA-256.
# The version comes from Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/LogMac-$VERSION.zip"

./scripts/build-app.sh
echo "Architectures: $(lipo -archs build/LogMac.app/Contents/MacOS/LogMac)"

rm -f "$ZIP"
# ditto keeps the bundle's symlinks, permissions, and signature intact; plain zip can break them.
ditto -c -k --keepParent build/LogMac.app "$ZIP"
echo "Built $ZIP"
shasum -a 256 "$ZIP"
