#!/bin/bash
# Hook: UserPromptSubmit
# Fires when user submits a prompt, before Claude processes it.

set -e
source "$(dirname "$0")/_lib.sh"

# Read hook payload from stdin.
payload=$(cat)

# Extract event-specific fields.
prompt=$(echo "$payload" | jq -r '.prompt // empty')

# Build data object with user prompt.
data=$(jq -n \
  --arg prompt "$prompt" \
  '{
    prompt: ($prompt | select(. != ""))
  }')

# Send frame to V10.
send_frame "presence" "UserPromptSubmit" "$data"
