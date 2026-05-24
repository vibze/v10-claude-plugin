#!/bin/bash
# Hook: SessionEnd
# Fires when a session terminates.

set -e
source "$(dirname "$0")/_lib.sh"

# Read hook payload from stdin.
payload=$(cat)

# SessionEnd has minimal event-specific data; just send the envelope.
data=$(jq -n '{}')

# Send frame to V10.
send_frame "presence" "SessionEnd" "$data"
