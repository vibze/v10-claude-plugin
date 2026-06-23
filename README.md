# V10 Bridge Plugin

A Claude Code plugin that signals V10 (Mac terminal app) with Claude Code lifecycle events via Unix domain socket.

## Purpose

Replaces process inspection heuristics with explicit event signaling. Fires on six Claude Code hooks:

- `SessionStart` — Claude Code session begins/resumes
- `UserPromptSubmit` — User submits a prompt
- `PreToolUse` — Tool call about to execute
- `PostToolUse` — Tool call succeeded
- `Stop` — Claude finishes responding
- `SessionEnd` — Session terminates

Each event emits one JSON frame **in-band** as a private OSC escape on the
terminal, allowing V10 to track Claude Code presence with high fidelity —
including over SSH, where the escape rides the PTY for free.

## Transport contract

**Mechanism**: a private **OSC 5113** escape written to the controlling tty
(`printf '\033]5113;<json>\007' > /dev/tty`). V10 catches it from the PTY
stream and attributes the frame to the tab whose terminal received it.

**Why OSC, not a socket**: it needs no `V10_*` env vars, no `ssh -R` socket
forwarding, and no `nc`/`socat` on the host — so it works identically
locally and on a remote Claude install. (Pre-0.3.0 used a Unix-domain
socket + `$V10_SOCKET`/`$V10_SESSION_ID`; those are gone.)

**tmux**: inside tmux the escape is wrapped in the passthrough DCS, so the
remote tmux must have `set -g allow-passthrough on`.

**Requirements**: a controlling tty (`/dev/tty`) and `jq`. No tty → no-op.

## Frame schema

```json
{
  "channel": "presence",
  "event": "SessionStart",
  "claude_pid": <int, owning claude/node PID — local liveness only>,
  "ts": <float, unix seconds with ms precision>,
  "data": {
    "model": "claude-sonnet-4-6",
    "source": "startup",
    "cwd": "/path/to/project"
  }
}
```

Event-specific `data` fields:

| Event              | data fields            | Examples                       |
|--------------------|------------------------|--------------------------------|
| `SessionStart`     | model, source, cwd     | model, source (startup/resume) |
| `UserPromptSubmit` | (empty)                | heartbeat only                 |
| `PreToolUse`       | tool_name              | Bash, Write, Edit, etc.        |
| `PostToolUse`      | tool_name              | Bash, Write, Edit, etc.        |
| `Stop`             | (empty)                | —                              |
| `SessionEnd`       | (empty)                | —                              |

The `usage` channel (`Update` event) additionally carries `tokens`,
`cost_usd`, and `turns`.

## Installation

```bash
# Install to user scope (available in all projects)
claude plugin install v10-bridge@vibze/v10-claude-plugin --scope user

# Or project scope (shared via .claude/settings.json)
claude plugin install v10-bridge@vibze/v10-claude-plugin --scope project
```

No environment setup is needed — just run `claude` inside a V10 tab (local
or SSH).

## Behavior

- **Non-blocking**: frames are a single `printf` to `/dev/tty`; failures are
  swallowed so a hook never fails Claude.
- **Silent**: all hook exit codes are 0.
- **No-op off-V10**: with no tty (headless/piped claude) the hooks do
  nothing; in a non-V10 terminal the OSC is an ignored escape.

## Troubleshooting

If activity isn't showing up in V10 (especially over SSH):

1. **Did the hook fire + reach a tty?** On the box where `claude` runs:
   ```bash
   export V10_BRIDGE_DEBUG=1   # then run claude in the V10 tab
   tail -f ~/.v10-bridge.log   # (or $V10_BRIDGE_DEBUG_FILE)
   ```
   Each event logs `HH:MM:SS <channel>/<event> tty=<y|n> tmux=<y|n>`.
   `tty=n` means no controlling terminal to emit on; `tmux=y` means the
   remote tmux needs `set -g allow-passthrough on`. (`claude --debug` also
   shows hook execution.)
2. **Did the frame reach the Mac?** In Console / `log`:
   ```bash
   log stream --predicate 'subsystem=="com.viktorten.v10" AND category=="Bridge"' --level debug
   ```
   `rx`/`apply` lines = working; `decode failed` = it arrived mangled
   (suspect tmux passthrough); nothing = it never arrived.

## Implementation notes

- `claude_pid` is the hook process PID (reasonably close to Claude's PID for tracking).
- Timestamps use Unix epoch with millisecond precision (`date +%s%N | sed 's/.\{6\}$//'`).
- Hook payload fields are extracted via `jq` and filtered (empty fields omitted from data).
- All hooks source `_lib.sh` for the common `send_frame` function.

## License

MIT
