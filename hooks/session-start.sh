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
