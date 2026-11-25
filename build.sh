#!/bin/zsh
# Builds Recorder.app into ./build.noindex and, with --install, copies it to ~/Applications.
# Self-test after installing:  open -W ~/Applications/Recorder.app --args --selftest /tmp/recorder-selftest.txt
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app=build.noindex/Recorder.app   # .noindex keeps Spotlight/Launchpad from listing a second copy
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Recorder "$app/Contents/MacOS/Recorder"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Recorder</string>
    <key>CFBundleDisplayName</key><string>Recorder</string>
    <key>CFBundleIdentifier</key><string>org.pope.recorder</string>
    <key>CFBundleExecutable</key><string>Recorder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Recorder records your audio interface or microphone onto tracks.</string>
</dict>
</plist>
PLIST

# Sign with the local self-signed certificate when present, so macOS keeps the
# microphone permission across rebuilds; otherwise fall back to ad-hoc signing.
identity="Pope Local Code Signing"
if security find-identity -p codesigning | grep -q "\"$identity\""; then
    codesign --force --sign "$identity" "$app"
else
    codesign --force --sign - "$app"
fi
echo "built $app"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Recorder.app
    cp -R "$app" ~/Applications/
    echo "installed ~/Applications/Recorder.app"
fi
