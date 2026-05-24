#!/bin/bash
# Hook: PreToolUse
# Fires before a tool call executes.

set -e
source "$(dirname "$0")/_lib.sh"

# Read hook payload from stdin.
payload=$(cat)

# Extract tool-specific fields.
tool_name=$(echo "$payload" | jq -r '.tool_name // empty')

# Build data object with tool name.
data=$(jq -n \
  --arg tool_name "$tool_name" \
  '{
    tool_name: ($tool_name | select(. != ""))
  }')

# Send frame to V10.
send_frame "presence" "PreToolUse" "$data"
