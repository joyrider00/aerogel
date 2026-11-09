#!/usr/bin/env bash
# Builds Aerogel.app (release, universal when possible) into ./build.
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  build and copy to /Applications
#   scripts/build-app.sh --run      build and launch
#   scripts/build-app.sh --demo     build and launch with the fake workspace
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Aerogel.app
VERSION=${VERSION:-0.1.0}

ARCHS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCHS[@]}" >/dev/null 2>&1; then
  echo "Universal build unavailable (needs full Xcode); building for this Mac only."
  ARCHS=()
fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN=$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Aerogel

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Aerogel"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Aerogel</string>
  <key>CFBundleDisplayName</key><string>Aerogel</string>
  <key>CFBundleIdentifier</key><string>com.aerogel.hud</string>
  <key>CFBundleExecutable</key><string>Aerogel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Sign with a stable identity so Keychain access survives rebuilds. Uses a local
# "Aerogel Local Signing" certificate if present (see scripts/make-signing-cert.sh),
# otherwise an ad-hoc signature (Keychain will re-prompt after every rebuild).
if [ -z "${SIGN_IDENTITY:-}" ]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "Aerogel Local Signing"; then
    SIGN_IDENTITY="Aerogel Local Signing"
  else
    SIGN_IDENTITY="-"
  fi
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null
echo "Signed with: $SIGN_IDENTITY"
echo "Built $APP"

case "${1:-}" in
  --install)
    rm -rf /Applications/Aerogel.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Aerogel.app"
    open /Applications/Aerogel.app ;;
  --run)  open "$APP" ;;
  --demo) open "$APP" --args --demo ;;
esac
