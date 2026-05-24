#!/bin/bash
# Common hook library for V10 bridge plugin

# Send frame to V10 via Unix domain socket.
# Usage: send_frame <channel> <event> <json_data>
# Returns 0 on success or socket errors (hook must not fail).
send_frame() {
  local channel="$1"
  local event="$2"
  local data="$3"
  
  # Socket is optional; silently no-op if unset or if V10_SESSION_ID is unset.
  [[ -z "$V10_SOCKET" ]] && return 0
  [[ -z "$V10_SESSION_ID" ]] && return 0
  
  # Build frame envelope.
  local claude_pid=$$  # Hook's PID; Claude invokes hooks, so this is reasonably close.
  local ts=$(date +%s%N | sed 's/.\{6\}$//')  # Unix float (seconds with ms precision).
  
  # Merge data into the frame.
  local frame=$(jq -n \
    --arg channel "$channel" \
    --arg event "$event" \
    --arg session_id "$V10_SESSION_ID" \
    --argjson app_pid "${V10_APP_PID:-0}" \
    --argjson claude_pid "$claude_pid" \
    --arg ts "$ts" \
    --argjson data "$data" \
    '{
      channel: $channel,
      event: $event,
      v10_session_id: $session_id,
      v10_app_pid: $app_pid,
      claude_pid: $claude_pid,
      ts: ($ts | tonumber),
      data: $data
    }')
  
  # Send one frame, then close. Short timeout (1s) so dead sockets don't hang Claude.
  echo "$frame" | nc -U -w 1 "$V10_SOCKET" >/dev/null 2>&1 || true
  
  return 0
}
