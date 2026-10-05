#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
backend_binary="${1:?Usage: bash scripts/build.sh /path/to/quarkdrive-webdav}"
if [[ ! -x "$backend_binary" ]]; then echo 'Backend binary is missing or not executable.' >&2; exit 1; fi
bundle_dir="$project_dir/build/fuck quark.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -sdk "$sdk_path" "$project_dir/Sources/QuarkCinema.swift" -o "$bundle_dir/Contents/MacOS/QuarkCinema" -framework Cocoa -framework NetFS -framework SwiftUI
cp -R "$project_dir/Resources/." "$bundle_dir/Contents/Resources/"
cp "$backend_binary" "$bundle_dir/Contents/Resources/quarkdrive-webdav"
cp "$project_dir/Info.plist" "$bundle_dir/Contents/Info.plist"
codesign --force --deep --sign - "$bundle_dir"
echo "Built: $bundle_dir"
