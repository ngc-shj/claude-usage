# claude-usage

Edit the source here, then run `./install.sh` — `~/.claude/usage/` holds copies
and is overwritten on the next install. The scheduler always executes the
installed copy, never this checkout, so a script change that is not installed
does not run. `scripts/install-usage-poller.sh` needs re-running only when a
unit file under `systemd/` or `launchd/` changed.

| Edit here | Lands at |
| --- | --- |
| `bin/*.sh` | `~/.claude/usage/` |
| `skills/*/` | `~/.claude/skills/` |
| `systemd/`, `launchd/` | `~/.config/systemd/user/`, `~/Library/LaunchAgents/` |

`~/.claude/skills/` is shared with other installers. Replace only the
directories this repo ships; never sweep that tree for unknown entries.

`scripts/install-usage-poller.sh` refuses to schedule a poller that differs from
`bin/claude-usage-poll.sh`, so run `install.sh` first.

## Tests

```bash
bats tests/
```

The two scripts are the only record of the plan's rate-limit history, and a
logging failure looks exactly like an uneventful window. Every change needs a
test that would fail without it — especially the ones asserting what is *not*
written to the log.
