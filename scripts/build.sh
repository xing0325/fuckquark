#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
backend_binary="${1:?Usage: bash scripts/build.sh /path/to/backends-directory}"
if [[ ! -x "$backend_binary/arm64/quarkdrive-webdav" || ! -x "$backend_binary/x86_64/quarkdrive-webdav" ]]; then echo 'Backend binary is missing or not executable.' >&2; exit 1; fi
bundle_dir="$project_dir/build/fuck quark.app"
rm -rf "$bundle_dir"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
for architecture in arm64 x86_64; do
    swiftc -O -target "$architecture-apple-macos13.0" -sdk "$sdk_path" "$project_dir/Sources/"*.swift -o "$project_dir/build/QuarkCinema-$architecture" -framework Cocoa -framework NetFS -framework SwiftUI -framework WebKit
 done
lipo -create "$project_dir/build/QuarkCinema-arm64" "$project_dir/build/QuarkCinema-x86_64" -output "$bundle_dir/Contents/MacOS/QuarkCinema"
cp -R "$project_dir/Resources/." "$bundle_dir/Contents/Resources/"
mkdir -p "$bundle_dir/Contents/Resources/backends/arm64" "$bundle_dir/Contents/Resources/backends/x86_64"
for architecture in arm64 x86_64; do
 cp "$backend_binary/$architecture/quarkdrive-webdav" "$bundle_dir/Contents/Resources/backends/$architecture/"
 done
cp "$project_dir/Info.plist" "$bundle_dir/Contents/Info.plist"
codesign --force --deep --sign - "$bundle_dir"
echo "Built: $bundle_dir"
