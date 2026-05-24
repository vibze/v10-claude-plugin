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

Each event sends one JSON frame over a UDS to V10, allowing the app to track Claude Code presence with high fidelity.

## Transport contract

**Socket location**: `$V10_SOCKET` (set by V10; read from environment)  
**Frame format**: One JSON line per event, terminated with `\n`  
**Channel**: `presence` (only channel in v0.1.0; extensible for future channels)

## Environment variables

The plugin requires two environment variables set by V10:

- `$V10_SOCKET` — Path to Unix domain socket (e.g., `$TMPDIR/v10-bridge-$UID.sock`)
- `$V10_SESSION_ID` — UUID identifying this Claude Code session
- `$V10_APP_PID` — PID of the V10 app process (optional; used in frame envelope)

If `$V10_SOCKET` or `$V10_SESSION_ID` are unset, the plugin silently no-ops. If `$V10_APP_PID` is unset, it defaults to 0 in frames.

## Frame schema

```json
{
  "channel": "presence",
  "event": "SessionStart",
  "v10_session_id": "<UUID from $V10_SESSION_ID>",
  "v10_app_pid": <int from $V10_APP_PID or 0>,
  "claude_pid": <int, PID of hook process>,
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
| `UserPromptSubmit` | prompt                 | User-supplied prompt text      |
| `PreToolUse`       | tool_name              | Bash, Write, Edit, etc.        |
| `PostToolUse`      | tool_name              | Bash, Write, Edit, etc.        |
| `Stop`             | (empty)                | —                              |
| `SessionEnd`       | (empty)                | —                              |

## Installation

```bash
# Install to user scope (available in all projects)
claude plugin install v10-bridge@vibze/v10-claude-plugin --scope user

# Or project scope (shared via .claude/settings.json)
claude plugin install v10-bridge@vibze/v10-claude-plugin --scope project
```

Then launch Claude Code with V10 environment variables:

```bash
export V10_SOCKET="$TMPDIR/v10-bridge-$UID.sock"
export V10_SESSION_ID="<uuid>"
export V10_APP_PID=12345
claude
```

## Behavior

- **Non-blocking**: Hooks use 1-second timeout on socket writes; dead sockets never hang Claude.
- **Silent errors**: All hook exit codes are 0, even on socket write failures. Errors logged to stderr only if needed.
- **Optional**: If `$V10_SOCKET` or `$V10_SESSION_ID` unset, hooks are a no-op with zero overhead.

## Implementation notes

- `claude_pid` is the hook process PID (reasonably close to Claude's PID for tracking).
- Timestamps use Unix epoch with millisecond precision (`date +%s%N | sed 's/.\{6\}$//'`).
- Hook payload fields are extracted via `jq` and filtered (empty fields omitted from data).
- All hooks source `_lib.sh` for the common `send_frame` function.

## License

MIT
