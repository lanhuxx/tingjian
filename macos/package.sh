#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="build/听笺.app"
stage="build/installer"
output="${1:?Provide an absolute output .pkg path}"
test -x "$app/Contents/Resources/Runtime/bin/python3.11"
mkdir -p "$stage/root"
ditto "$app" "$stage/root/听笺.app"
pkgbuild --root "$stage/root" --component-plist Components.plist --install-location /Applications \
  --identifier local.funasr.transcription.pkg --version 0.8.2 "$stage/听笺组件.pkg"
productbuild --distribution Distribution.xml --package-path "$stage" "$output"
