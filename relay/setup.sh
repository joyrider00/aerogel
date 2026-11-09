#!/usr/bin/env bash
# One-time setup of the Slack Glass team server on your Cloudflare account. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

npm install --silent
npx wrangler whoami 2>/dev/null | grep -q "You are logged in" || npx wrangler login

echo "Deploying the team server…"
URL=$(npx wrangler deploy 2>&1 | tee /dev/stderr | grep -Eo 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -1)
[ -n "$URL" ] || { echo "Couldn't find the server's address in the deploy output."; exit 1; }

secrets=$(npx wrangler secret list 2>/dev/null || echo "[]")
has() { grep -q "\"$1\"" <<<"$secrets"; }

has STATE_SECRET || openssl rand -hex 32 | npx wrangler secret put STATE_SECRET >/dev/null

echo
echo "Opening $URL/setup — click \"Create the Slack app\" there, then come back here."
open "$URL/setup"
for name in SLACK_CLIENT_ID SLACK_CLIENT_SECRET SLACK_SIGNING_SECRET SLACK_APP_TOKEN; do
  if has "$name"; then echo "$name is already set."; continue; fi
  case $name in
    SLACK_CLIENT_ID) label="Client ID" ;;
    SLACK_CLIENT_SECRET) label="Client Secret" ;;
    SLACK_SIGNING_SECRET) label="Signing Secret" ;;
    SLACK_APP_TOKEN) label="App-level token (xapp-…, scope authorizations:read)" ;;
  esac
  read -r -s -p "Paste the $label: " value </dev/tty; echo
  printf '%s' "$value" | npx wrangler secret put "$name" >/dev/null
done

echo
echo "Done. Your team installs Slack Glass with:"
echo
echo "    curl -fsSL $URL/install | bash"
