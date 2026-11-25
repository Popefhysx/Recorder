#!/bin/zsh
# Builds Recorder.app into ./build.noindex and, with --install, copies it to ~/Applications.
# Self-test after installing:  open -W ~/Applications/Recorder.app --args --selftest /tmp/recorder-selftest.txt
set -euo pipefail
cd "$(dirname "$0")"

# Voice Clean runs DeepFilterNet's own command-line build (MIT/Apache-2.0). It is fetched once
# from the project's GitHub release into Vendor/ (not committed: 28 MB) and checked against a
# known SHA-256. Without it the app still builds; Voice Clean then says it isn't installed.
dfn=Vendor/deep-filter
dfn_url=https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-aarch64-apple-darwin
dfn_sha=4601e7f4e4c03e59a4c5b5000216ef3add3e808799cfccd95e14e83ea4611081
if [[ ! -x $dfn && "$(uname -m)" == arm64 ]]; then
    mkdir -p Vendor
    echo "Downloading DeepFilterNet for Voice Clean (28 MB, once)..."
    # gh is used when present: it was much faster than plain curl on this connection.
    if command -v gh >/dev/null && gh release download v0.5.6 -R Rikorose/DeepFilterNet -p "${dfn_url:t}" -O "$dfn.part" --clobber 2>/dev/null \
       || curl -fL --retry 2 --connect-timeout 20 --progress-bar "$dfn_url" -o "$dfn.part"; then :; fi
    if [[ -f "$dfn.part" && "$(shasum -a 256 "$dfn.part" | cut -d' ' -f1)" == $dfn_sha ]]; then
        mv "$dfn.part" "$dfn" && chmod +x "$dfn"
    else
        rm -f "$dfn.part"; echo "warning: couldn't fetch DeepFilterNet; building without Voice Clean" >&2
    fi
fi

swift build -c release
app=build.noindex/Recorder.app   # .noindex keeps Spotlight/Launchpad from listing a second copy
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Recorder "$app/Contents/MacOS/Recorder"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
[[ -x $dfn ]] && cp "$dfn" "$app/Contents/MacOS/deep-filter"

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
security find-identity -p codesigning | grep -q "\"$identity\"" || identity=-
# The helper is signed first: an app's signature covers the code nested inside it.
[[ -x "$app/Contents/MacOS/deep-filter" ]] && codesign --force --sign "$identity" "$app/Contents/MacOS/deep-filter"
codesign --force --sign "$identity" "$app"
echo "built $app"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Recorder.app
    cp -R "$app" ~/Applications/
    echo "installed ~/Applications/Recorder.app"
fi
