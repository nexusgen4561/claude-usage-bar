#!/bin/bash
# Builds "Claude Usage.app" — a menu-bar-only app bundle — into ~/Applications.
# Override the destination with APP_DIR=/Applications ./build.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${APP_DIR:-$HOME/Applications}/Claude Usage.app"
BIN="$APP/Contents/MacOS/ClaudeUsageBar"
DEPLOYMENT_TARGET=13.0

# Take the version from the latest git tag so Finder's Get Info stays honest
# without a constant to remember to bump. Tarball checkouts have no tags.
VERSION="$(git -C "$SRC_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
VERSION="${VERSION:-0.0.0-dev}"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "error: swiftc not found. Install the Xcode command line tools with:" >&2
    echo "         xcode-select --install" >&2
    exit 1
fi

echo "==> Compiling (arm64 + x86_64)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Built as a universal binary so one build works on Apple silicon and Intel.
# A missing cross-compilation SDK is not fatal — the host slice is enough.
slices=()
for arch in arm64 x86_64; do
    # -swift-version 5 keeps this off Swift 6's strict concurrency checking.
    if swiftc -O -swift-version 5 \
        -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" \
        -framework AppKit \
        -o "$WORK/$arch" \
        "$SRC_DIR/ClaudeUsageBar.swift" 2>"$WORK/$arch.log"
    then
        slices+=("$WORK/$arch")
    else
        echo "    ($arch slice unavailable — skipping)"
    fi
done

if [ ${#slices[@]} -eq 0 ]; then
    echo "error: the compile failed for every architecture:" >&2
    cat "$WORK"/*.log >&2
    exit 1
fi

lipo -create -output "$BIN" "${slices[@]}"
echo "    $(lipo -archs "$BIN")"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Usage</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleIdentifier</key>      <string>com.local.claudeusagebar</string>
    <key>CFBundleExecutable</key>      <string>ClaudeUsageBar</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>${DEPLOYMENT_TARGET}</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>             <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "    (ad-hoc signing skipped)"

echo "==> Built: $APP"
echo "    Run it with: open -a \"$APP\""
