#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="$project_dir/build/fuck quark.app"
[[ -d "$app" ]] || { echo 'Build the application first.' >&2; exit 1; }
mkdir -p "$project_dir/dist"
stage="$(mktemp -d /tmp/fuckquark-package.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
cp "$project_dir/docs/安装说明.txt" "$stage/安装说明.txt"
hdiutil create -volname 'fuck quark' -srcfolder "$stage" -ov -format UDZO "$project_dir/dist/fuckquark-0.2.0-universal.dmg"
(cd "$project_dir/dist" && shasum -a 256 fuckquark-0.2.0-universal.dmg > SHA256SUMS.txt)
