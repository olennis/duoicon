#!/bin/sh
set -eu
cd "$(dirname "$0")"
.build/release/UnifiedMenuBar --build-favicon
sips -s format ico Assets/favicon.png --out Assets/favicon.ico >/dev/null
