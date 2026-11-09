#!/usr/bin/env bash
# Builds a universal Slack Glass.app and publishes it as a GitHub release. The team install command
# (curl <team server>/install | bash) downloads the latest one.
#   scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release.sh <version>}
VERSION=$VERSION scripts/build-app.sh
lipo -archs "build/Slack Glass.app/Contents/MacOS/SlackGlass" | grep -q x86_64 || echo "Note: this build is Apple Silicon only."
rm -f build/Slack-Glass.zip
ditto -c -k --keepParent "build/Slack Glass.app" build/Slack-Glass.zip
gh release create "v$VERSION" build/Slack-Glass.zip --title "Slack Glass $VERSION" \
  --notes "Install with your team's command: \`curl -fsSL <your team server>/install | bash\`"
