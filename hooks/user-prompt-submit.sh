#!/bin/bash
# Hook: UserPromptSubmit
# Fires when user submits a prompt, before Claude processes it.

set -e
source "$(dirname "$0")/_lib.sh"

# Drain stdin (the hook payload) but don't forward the prompt text — it's
# only a heartbeat to V10, and the prompt could be large for an in-band
# OSC payload.
cat >/dev/null

# Send frame to V10 (empty data — this event is purely a liveness signal).
send_frame "presence" "UserPromptSubmit" "{}"
