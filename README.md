# claude-usage

A local, timestamped history of the Claude.ai subscription's rate-limit
percentages — the thing `/usage` prints and then forgets.

Two writers append to one JSONL log, `~/.claude/usage-log.jsonl`:

| | |
| --- | --- |
| `bin/statusline-usage.sh` | Claude Code's status line. Renders the model and both percentages, and records whatever the session payload carried. |
| `bin/claude-usage-poll.sh` | A background poller. Reads the same figures from the internal OAuth usage endpoint every five minutes, without sending a model prompt. |

They share one lock, one monotonic frontier, one privacy policy and one record
format, because the poller feeds its response through the status line script
rather than writing the log itself.

## Install

```bash
bash install.sh                        # -> ~/.claude/usage/
bash scripts/install-usage-poller.sh   # systemd (Linux) or launchd (macOS)
tail -f ~/.claude/usage-log.jsonl
```

`install.sh` requires `jq`, `curl` and `awk`. Then point Claude Code's status
line at the installed copy, in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/usage/statusline-usage.sh"
}
```

The install target is `~/.claude/usage/`, not `~/.claude/hooks/`: an installer
that manages `hooks/` as its own source of truth (such as
[claude-code-config](https://github.com/ngc-shj/claude-code-config)) deletes
top-level scripts there that it does not ship, so a copy placed alongside its
hooks would vanish on its next run. That statusLine string is the only thing
tying the two repos together.

## What a record means

```json
{"at":"2026-08-12T01:05:00Z",
 "five_hour":{"used_percentage":12,"resets_at":1786222800},
 "seven_day":{"used_percentage":34,"resets_at":1786827599}}
```

A line is appended only when a percentage or a reset boundary **changes**, so an
old line means the figure has not moved, not that sampling stopped.

Subtracting two readings gives an **upper bound** on what happened between them
— the log is account-wide, so another device's work lands in the same figure.
The difference is **invalid**, not merely loose, when a window rolled over
between the two readings, when either window is `null`, or when the reset
boundaries differ.

Each window is judged alone. A window that is missing, that went backwards, or
whose reset moved backwards is written as `null` rather than carried forward —
carrying it forward would invent an observation that was never made. Consumers
subtracting one window skip the lines where it is `null`.

**Resolution is 1%.** Every reading observed so far has been a whole percent,
and the two that looked otherwise — `14.000000000000002`, `28.000000000000004`
— are `0.14 * 100` and `0.28 * 100` to the bit. Nothing here rounds, so a
genuinely fractional reading would be logged verbatim and would settle it.

## Privacy and security

Only the timestamp, the two percentages and their reset boundaries are written.
The status-line payload also carries the session id, the transcript path and the
working directory; none of them reach the log, and `tests/` pins that.

The poller reads the existing Claude Code OAuth access token from
`~/.claude/.credentials.json` and passes it to `curl` over stdin — never in
process arguments, environment variables, logs or temporary files. The log and
its state file are mode 600.

The usage endpoint is used by Claude Code itself but is not a documented public
API, so the response is validated strictly and nothing is written if its schema
changes. HTTP 429 honours `Retry-After` with a five-minute floor; 401/403 and
schema failures surface in the scheduler's diagnostics.

## Operating the poller

Linux:

```bash
systemctl --user status claude-usage-poll.timer
journalctl --user -u claude-usage-poll.service
systemctl --user disable --now claude-usage-poll.timer   # stop
```

macOS:

```bash
launchctl print "gui/$(id -u)/com.ngc-shj.claude-usage-poll"
tail -f ~/.claude/state/usage-poll-launchd.log
launchctl disable "gui/$(id -u)/com.ngc-shj.claude-usage-poll"   # stop
launchctl bootout "gui/$(id -u)/com.ngc-shj.claude-usage-poll"
```

No samples are taken while the machine is suspended or offline.

## Tests

```bash
bats tests/
```

## License

MIT
