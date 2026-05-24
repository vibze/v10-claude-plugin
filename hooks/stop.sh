#!/bin/bash
# Hook: Stop
# Fires when Claude finishes responding.

set -e
source "$(dirname "$0")/_lib.sh"

# Read hook payload from stdin (minimal for Stop event).
payload=$(cat)

# Stop has minimal event-specific data; just send the envelope.
data=$(jq -n '{}')

# Send frame to V10.
send_frame "presence" "Stop" "$data"
