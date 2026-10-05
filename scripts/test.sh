#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/fuckquark-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$project_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); dest=Path(sys.argv[2]); source=(root/'Sources/main.swift').read_text().split('\nif checkOnly {',1)[0]
(dest/'main.swift').write_text(source+'\n'+(root/'Tests/checks.swift').read_text())
PY
swiftc -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" "$project_dir/Sources/Setup.swift" "$check_dir/main.swift" -o "$check_dir/checks" -framework Cocoa -framework NetFS -framework SwiftUI -framework WebKit
FQ_SUPPORT_DIR="$check_dir/profile" "$check_dir/checks" "$@"
