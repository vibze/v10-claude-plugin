#!/bin/bash
# Common hook library for V10 bridge plugin

# Our own version, read once from the manifest beside the hooks dir. V10
# uses it to nudge when the installed plugin is outdated (local or remote).
# Empty if unreadable — then no version travels and V10 simply can't nudge.
V10_PLUGIN_VERSION="${V10_PLUGIN_VERSION:-$(jq -r '.version // empty' "$(dirname "${BASH_SOURCE[0]}")/../.claude-plugin/plugin.json" 2>/dev/null)}"

# Send a frame to V10 *in-band* as a private OSC 5113 escape written to the
# controlling tty. The bytes ride the PTY — locally or over ssh/tmux — and
# V10 attributes the frame to the tab whose terminal received it, so no
# V10_* env vars or socket forwarding are needed. This is what makes the
# bridge work on remote Claude installs.
# Usage: send_frame <channel> <event> <json_data>
# Always returns 0 (a hook must never fail Claude).
send_frame() {
  local channel="$1"
  local event="$2"
  local data="$3"

  # Opt-in troubleshooting trace (set V10_BRIDGE_DEBUG=1). Logged BEFORE
  # the tty check so you can tell a hook that fired-but-had-no-tty from one
  # that never ran. Captures whether a tty is reachable and tmux state —
  # the two things that decide if the OSC can get back to the Mac.
  if [[ -n "$V10_BRIDGE_DEBUG" ]]; then
    printf '%s %s/%s tty=%s tmux=%s\n' \
      "$(date +%T)" "$channel" "$event" \
      "$([[ -w /dev/tty ]] && echo y || echo n)" \
      "$([[ -n "$TMUX" ]] && echo y || echo n)" \
      >> "${V10_BRIDGE_DEBUG_FILE:-$HOME/.v10-bridge.log}" 2>/dev/null || true
  fi

  # Need a controlling terminal to write the escape to. No-op in headless
  # / piped claude (no tty == not inside a V10 terminal anyway).
  [[ -w /dev/tty ]] || return 0

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

  # Build the frame. No v10_session_id / v10_app_pid: V10 knows the session
  # from the receiving terminal. claude_pid is for local liveness only.
  local frame
  frame=$(jq -nc \
    --arg channel "$channel" \
    --arg event "$event" \
    --argjson claude_pid "$claude_pid" \
    --arg ts "$ts" \
    --arg plugin_version "$V10_PLUGIN_VERSION" \
    --argjson data "$data" \
    '{
      channel: $channel,
      event: $event,
      claude_pid: $claude_pid,
      ts: ($ts | tonumber),
      plugin_version: ($plugin_version | select(. != "")),
      data: $data
    }') || return 0

  # Emit as OSC 5113 ; <json> BEL. Inside tmux, wrap in the passthrough
  # DCS (doubling ESC) so the sequence reaches the outer terminal —
  # requires `set -g allow-passthrough on` on the remote tmux.
  local esc=$'\033'
  local osc="${esc}]5113;${frame}"$'\007'
  if [[ -n "$TMUX" ]]; then
    local doubled="${osc//$esc/$esc$esc}"
    osc="${esc}Ptmux;${doubled}${esc}\\"
  fi
  printf '%s' "$osc" > /dev/tty 2>/dev/null || true

  return 0
}
