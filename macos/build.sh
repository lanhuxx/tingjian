#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="build/听笺.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X Info.plist "$app/Contents/"
cp -X desktop_worker.py transcribe.py models.json "$app/Contents/Resources/"
swiftc -module-cache-path "$PWD/build/module-cache" -parse-as-library \
    -target arm64-apple-macos26.0 FunASR.swift SpeakerHeaders.swift -o build/FunASR-executable
mv -f build/FunASR-executable "$app/Contents/MacOS/FunASR"
swift -module-cache-path "$PWD/build/module-cache" AppIcon.swift build/AppIcon.iconset "$app/Contents/Resources/AppIcon.icns"
runtime_funasr="$app/Contents/Resources/Runtime/lib/python3.11/site-packages/funasr/auto/auto_model.py"
if [[ -f "$runtime_funasr" ]]; then
    python3 patch_funasr_progress.py "$runtime_funasr"
fi
codesign --force --sign - "$app"
codesign --verify --strict "$app"
