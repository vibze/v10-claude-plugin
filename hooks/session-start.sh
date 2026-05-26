#!/bin/bash
# Hook: SessionStart
# Fires when a session begins or resumes.

set -e
source "$(dirname "$0")/_lib.sh"

# Read hook payload from stdin.
payload=$(cat)

# Extract event-specific fields from hook payload.
model=$(echo "$payload" | jq -r '.model // empty')
source=$(echo "$payload" | jq -r '.source // empty')
cwd=$(echo "$payload" | jq -r '.cwd // empty')

# Build data object with SessionStart-specific fields.
data=$(jq -n \
  --arg model "$model" \
  --arg source "$source" \
  --arg cwd "$cwd" \
  '{
    model: ($model | select(. != "")),
    source: ($source | select(. != "")),
    cwd: ($cwd | select(. != ""))
  }')

# Send frame to V10.
send_frame "presence" "SessionStart" "$data"

# When this session is inside a V10 tab (V10_BROWSER_SOCK exported by
# the Mac app), nudge Claude to use the embedded `v10-browser` MCP
# server instead of any other browser tool (browsermcp, playwright,
# puppeteer, etc.) the user has configured. The embedded browser is
# scoped to this single tab and does not touch the user's real
# browser, so it's the right tool here.
if [[ -n "$V10_BROWSER_SOCK" ]]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: "Inside a V10 tab. For testing/inspecting/screenshotting web UIs and interacting with rendered pages, use the `v10-browser` MCP server (navigate / screenshot / snapshot / eval_js). It runs a sandboxed per-tab WKWebView the user can see. Prefer it over browsermcp/playwright/puppeteer. WebFetch is still fine for plain text-content fetches that don't need rendering."
    }
  }'
fi
