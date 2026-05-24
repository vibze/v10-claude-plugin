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
  
  # Walk up the process tree from the hook to find the long-lived Claude
  # process. The hook itself ($$) dies on exit; $PPID is typically the
  # bash that ran the hook command — also short-lived. The Claude process
  # is the first ancestor whose `comm` is `claude` (the launcher) or
  # `node` (the actual long-running interpreter that Claude Code is
  # implemented on). Falls back to $PPID if no match found.
  local claude_pid
  claude_pid=$(
    pid=$PPID
    while [[ $pid -gt 1 ]]; do
      name=$(ps -o comm= -p "$pid" 2>/dev/null | awk -F/ '{print $NF}' | tr -d ' ')
      if [[ "$name" == "claude" || "$name" == "node" ]]; then
        echo "$pid"
        exit 0
      fi
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [[ -z "$pid" || "$pid" == "0" ]] && break
    done
    echo "$PPID"
  )
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
