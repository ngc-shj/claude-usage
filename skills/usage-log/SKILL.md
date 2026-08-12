---
name: usage-log
description: "Read the local Claude.ai rate-limit history in ~/.claude/usage-log.jsonl: current utilization and headroom, time to window reset, and what a span of work cost. Refuses differences that span a window rollover instead of returning a wrong number. Use this skill when: asked how much of the plan/quota/limit is used or left; asked when the five-hour or weekly window resets; asked what a batch, a session or the last N hours cost; asked whether there is room to launch more agents; asked to read or summarize the usage log."
---

# Usage Log Skill

`~/.claude/usage-log.jsonl` is the only local record of the plan's rate-limit
percentages over time — `/usage` prints a figure and forgets it. This skill
reads that history.

Run the query tool; do not hand-roll `jq` over the log. The refusals below are
the reason it exists, and an ad-hoc subtraction silently skips all of them.

```bash
bash ~/.claude/usage/usage-query.sh now
bash ~/.claude/usage/usage-query.sh diff --from -90m
bash ~/.claude/usage/usage-query.sh diff --from 2026-08-11T12:00:00Z --to 2026-08-11T16:00:00Z
bash ~/.claude/usage/usage-query.sh history -n 20
```

`--from`/`--to` take an ISO 8601 instant, a Unix epoch, or an offset back from
now (`-90m`, `-6h`, `-2d`). `--to` defaults to now.

## Reading the answer honestly

**A difference is an UPPER BOUND, not a cost.** The log is account-wide, so
anything else you or another device did lands in the same figure. Report it as
"at most N points", never as "this batch used N".

**Refusals are answers.** When `diff` says INVALID, do not work around it by
subtracting two lines yourself. It means one of:

| Refusal | Why no number is safe |
| --- | --- |
| the window rolled over inside the span | The two readings describe different windows. The difference can be negative or spuriously small — it is not conservative in either direction. |
| no reading at or before the start | There is no baseline. The earliest reading is not one. |
| STALE (in `now`) | The window that reading describes has already ended, so the percentage belongs to a window that no longer exists. Say the poller has not sampled the new window; do not present the old figure as current. |

If a five-hour span is refused, the seven-day line usually still answers — it
rolls over weekly, so it survives spans that break the five-hour window. Quote
whichever window returned a number and say which one did.

**Resolution is 1%.** Every reading observed so far is a whole percent, so a
difference of 1 point is one quantum, not a precise measurement. Do not present
sub-point precision even when the JSON carries trailing digits
(`14.000000000000002` is `0.14 * 100` in binary floating point).

**A stale-looking line is not missing data.** The log appends only when a
figure changes, so an old timestamp means the figure has not moved. It is only
a problem when the window it names has already reset — which `now` reports as
STALE.

## What this cannot tell you

- **Per-session, per-agent or per-model attribution.** Only two account-wide
  percentages are recorded, deliberately: no session id, transcript path or
  working directory is ever written to the log.
- **Token counts.** The windows are percentages of a plan allowance.
- **Anything while the machine was suspended or offline.** The poller samples
  every five minutes; gaps are real gaps, and a span across one is still valid
  as long as the window did not roll over.

## If the log is missing or empty

The recorder may not be installed or the poller may not be running:

```bash
systemctl --user status claude-usage-poll.timer          # Linux
launchctl print "gui/$(id -u)/com.ngc-shj.claude-usage-poll"   # macOS
```

Both writers are in the claude-usage repo. Say what is wrong rather than
estimating a figure from another source.
