#!/usr/bin/env bash
# Read the usage log and answer three questions about it: what the figures are
# now, what a span of work cost, and what the recent readings were.
#
# The arithmetic is trivial. REFUSING it is the point. A difference between two
# readings is a valid upper bound only while both ends sit in the same window;
# across a rollover it can come out negative or spuriously small, and it looks
# exactly like a real answer. So every span is judged per window and reported
# as invalid rather than printed. Nothing here estimates, extrapolates or
# rounds — every number returned was measured.
#
# Usage:
#   usage-query.sh now
#   usage-query.sh diff --from <when> [--to <when>]
#   usage-query.sh history [-n N]
#
# <when> is an ISO 8601 instant (2026-08-11T16:00:00Z), a Unix epoch, or an
# offset back from now (-90m, -6h, -2d).
set -u

LOG="${CLAUDE_USAGE_LOG:-$HOME/.claude/usage-log.jsonl}"
NOW="$(date +%s)"

warn() { printf 'usage-query: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"
[ -r "$LOG" ] || die "no usage log at $LOG"
[ -s "$LOG" ] || die "usage log is empty: $LOG"

# An instant, however it was written. A bare number is already an epoch; an
# offset is resolved against this run's clock; anything else must parse as ISO
# 8601 or it is an error, never a guess.
parse_when() {
  local spec="$1" n unit mult
  case "$spec" in
    -[0-9]*[smhd])
      n="${spec#-}"; unit="${n#"${n%?}"}"; n="${n%?}"
      case "$unit" in
        s) mult=1 ;; m) mult=60 ;; h) mult=3600 ;; d) mult=86400 ;;
      esac
      printf '%s' "$((NOW - n * mult))"
      ;;
    *[!0-9]*)
      jq -rn --arg t "$spec" '$t | fromdateiso8601' 2>/dev/null ||
        die "cannot read '$spec' as a time: use ISO 8601, an epoch, or -90m/-6h/-2d"
      ;;
    '') die "empty time" ;;
    *) printf '%s' "$spec" ;;
  esac
}

# Shared jq definitions. `latest_at` is the one that matters: the log appends
# only on change, so the value in force at an instant is the last reading at or
# before it — not the nearest one, and never a value carried forward past a
# window it no longer describes.
JQ_LIB='
def dur:
  if . < 0 then "-" + (- . | dur)
  else . as $s
    | ($s / 86400 | floor) as $d
    | (($s % 86400) / 3600 | floor) as $h
    | (($s % 3600) / 60 | floor) as $m
    | if $d > 0 then "\($d)d\($h)h"
      elif $h > 0 then "\($h)h\($m)m"
      else "\($m)m" end
  end;
def at_epoch: .at | fromdateiso8601;
def latest_at($w; $t): [ .[] | select(at_epoch <= $t and .[$w] != null) ] | last;
def pct: .used_percentage;
def signed: if . >= 0 then "+\(.)" else "\(.)" end;
'

WINDOWS='["five_hour","seven_day"]'

read_log() {
  jq -s "$@" "$LOG" 2>/dev/null ||
    die "could not parse $LOG as JSONL — a hand-edited or truncated line will do this"
}

cmd_now() {
  read_log -r --argjson now "$NOW" "$JQ_LIB"'
    . as $rows
    | '"$WINDOWS"'
    | map(. as $w
        | ($rows | latest_at($w; $now)) as $r
        | if $r == null then "\($w)  no reading in the log"
          else
            ($r[$w].resets_at - $now) as $left
            | ($now - ($r | at_epoch)) as $age
            | if $left <= 0 then
                "\($w)  STALE: the window this reading describes ended \(- $left | dur) ago and nothing has been recorded since — the figure below belongs to a window that no longer exists.\n           \($r[$w] | pct)% used as of \($r.at)"
              else
                "\($w)  \($r[$w] | pct)% used, \(100 - ($r[$w] | pct)) left, resets in \($left | dur) (\($r[$w].resets_at | todate))\n           read \($r.at), \($age | dur) ago"
              end
          end)
    | .[]'
}

cmd_diff() {
  local from="" to="$NOW"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) [ "$#" -ge 2 ] || die "--from needs a value"; from="$(parse_when "$2")"; shift 2 ;;
      --to)   [ "$#" -ge 2 ] || die "--to needs a value";   to="$(parse_when "$2")";   shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$from" ] || die "diff needs --from"
  [ "$from" -lt "$to" ] || die "--from must be earlier than --to"

  read_log -r --argjson from "$from" --argjson to "$to" "$JQ_LIB"'
    . as $rows
    | '"$WINDOWS"'
    | map(. as $w
        | ($rows | latest_at($w; $from)) as $a
        | ($rows | latest_at($w; $to)) as $b
        | if $a == null then
            "\($w)  INVALID: no reading of this window at or before \($from | todate), so there is nothing to subtract from"
          elif $b == null then
            "\($w)  INVALID: no reading of this window at or before \($to | todate)"
          elif $a.at == $b.at then
            "\($w)  no change: both ends resolve to the same reading (\($a.at), \($a[$w] | pct)%) — the figure did not move in this span"
          elif $a[$w].resets_at != $b[$w].resets_at then
            "\($w)  INVALID: the window rolled over inside this span (resets \($a[$w].resets_at | todate) -> \($b[$w].resets_at | todate)). A difference across a boundary is not conservative in either direction, so no number is given."
          else
            (($b[$w] | pct) - ($a[$w] | pct)) as $d
            | "\($w)  \($d | signed) points  (\($a[$w] | pct)% -> \($b[$w] | pct)%)  UPPER BOUND — the log is account-wide, so anything else you or another device did is in this figure\n           \($a.at) -> \($b.at), one window resetting \($a[$w].resets_at | todate)"
          end)
    | .[]'
}

cmd_history() {
  local n=10
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n) [ "$#" -ge 2 ] || die "-n needs a value"; n="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$n" in ''|*[!0-9]*) die "-n takes a count" ;; esac
  [ "$n" -gt 0 ] || die "-n takes a count above zero"

  read_log -r --argjson n "$n" '
    .[- $n:]
    | .[]
    | "\(.at)  5h \(if .five_hour == null then "-" else "\(.five_hour.used_percentage)%" end)  7d \(if .seven_day == null then "-" else "\(.seven_day.used_percentage)%" end)"'
}

case "${1:-now}" in
  now)     shift 2>/dev/null; [ "$#" -eq 0 ] || die "now takes no arguments"; cmd_now ;;
  diff)    shift; cmd_diff "$@" ;;
  history) shift; cmd_history "$@" ;;
  -h|--help|help)
    sed -n '/^# Usage:/,/^# offset back/p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown command: $1 (try: now, diff, history)" ;;
esac
