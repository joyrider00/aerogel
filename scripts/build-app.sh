#!/usr/bin/env bash
# Builds "Slack Glass.app" (release, universal when possible) into ./build.
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  build, copy to /Applications and launch
#   scripts/build-app.sh --run      build and launch
#   scripts/build-app.sh --demo     build and launch with a fake workspace (no Slack needed)
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Slack Glass"
EXE=SlackGlass
APP="build/$NAME.app"
VERSION=${VERSION:-0.1.0}

ARCHS=(--arch arm64 --arch x86_64)
if swift build -c release "${ARCHS[@]}" >/dev/null 2>&1; then
  BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$EXE
else
  # Multi-arch builds need full Xcode. Without it, build each architecture on its own and join them.
  BIN=build/$EXE.universal
  mkdir -p build
  PARTS=()
  for T in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
    if swift build -c release --triple "$T"; then
      PARTS+=("$(swift build -c release --triple "$T" --show-bin-path)/$EXE")
    fi
  done
  [ ${#PARTS[@]} -gt 0 ] || { echo "Build failed."; exit 1; }
  [ ${#PARTS[@]} -eq 2 ] || echo "Couldn't build both architectures; this build runs on this kind of Mac only."
  lipo -create "${PARTS[@]}" -output "$BIN"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.joyrider00.slackglass</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>io.github.joyrider00.slackglass</string>
      <key>CFBundleURLSchemes</key><array><string>slackglass</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature by default (nothing depends on a stable identity). Set SIGN_IDENTITY to use your own.
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP" >/dev/null
echo "Built $APP"

case "${1:-}" in
  --install)
    # Quit the running copy, or macOS keeps the old version running and just brings it forward.
    osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq "$EXE" || break; sleep 0.3; done
    pkill -x "$EXE" 2>/dev/null || true
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$NAME.app"
    open "/Applications/$NAME.app" ;;
  --run)  open "$APP" ;;
  --demo) open "$APP" --args --demo ;;
esac
