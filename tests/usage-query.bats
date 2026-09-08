#!/usr/bin/env bats
# What is under test is not the subtraction — it is the refusal. A span that
# crosses a window rollover must produce no number at all, because a wrong
# number here is indistinguishable from a right one.

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin/usage-query.sh"
  export CLAUDE_USAGE_LOG="$BATS_TEST_TMPDIR/usage-log.jsonl"
  # Fixtures below are built relative to NOW, and the script is compared against
  # it. Left to read its own clock, the script lands a second later than the
  # fixture whenever the run crosses a second boundary, and an exact assertion
  # like "resets in 1h0m" comes out 59m instead.
  NOW="$(date +%s)"
  export CLAUDE_USAGE_NOW="$NOW"
}

# $1 seconds before now, $2/$3 percentages, $4/$5 reset boundaries as seconds
# from now. Times are relative so the fixtures stay valid whenever they run.
row() {
  local at=$((NOW - $1)) five_reset=$((NOW + $4)) seven_reset=$((NOW + $5))
  jq -cn --argjson at "$at" --argjson f "$2" --argjson s "$3" \
     --argjson fr "$five_reset" --argjson sr "$seven_reset" \
     '{at: ($at | todate),
       five_hour: {used_percentage: $f, resets_at: $fr},
       seven_day: {used_percentage: $s, resets_at: $sr}}' \
    >> "$CLAUDE_USAGE_LOG"
}

@test "now reports utilization, headroom and time to reset" {
  row 300 12 40 3600 604800
  run bash "$SCRIPT" now
  [ "$status" -eq 0 ]
  [[ "$output" == *"five_hour  12% used, 88 left"* ]]
  [[ "$output" == *"seven_day  40% used, 60 left"* ]]
  [[ "$output" == *"resets in 1h0m"* ]]
}

@test "the instant every answer is relative to can be pinned" {
  row 300 12 40 3600 604800
  export CLAUDE_USAGE_NOW="$((NOW + 1800))"
  run bash "$SCRIPT" now
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets in 30m"* ]]
}

@test "an unreadable pinned instant is an error, not a silent fallback" {
  row 300 12 40 3600 604800
  export CLAUDE_USAGE_NOW="yesterday"
  run bash "$SCRIPT" now
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an epoch second"* ]]
}

@test "now calls a reading STALE when its window has already ended" {
  # The window ended 10 minutes ago and nothing was recorded since, so the
  # percentage describes a window that no longer exists.
  row 3600 90 40 -600 604800
  run bash "$SCRIPT" now
  [ "$status" -eq 0 ]
  [[ "$output" == *"five_hour  STALE"* ]]
  [[ "$output" == *"no longer exists"* ]]
  # The seven-day window is judged separately and is still live.
  [[ "$output" == *"seven_day  40% used"* ]]
}

@test "an old reading in a live window is not stale" {
  # The log appends only on change, so an old line means the figure has not
  # moved. Treating age alone as staleness would reject a valid answer.
  row 14400 12 40 3600 604800
  run bash "$SCRIPT" now
  [[ "$output" != *"STALE"* ]]
  [[ "$output" == *"12% used"* ]]
}

@test "diff inside one window returns the rise, labelled an upper bound" {
  row 7200 10 40 3600 604800
  row 600 17 44 3600 604800
  run bash "$SCRIPT" diff --from -2h
  [ "$status" -eq 0 ]
  [[ "$output" == *"five_hour  +7 points  (10% -> 17%)"* ]]
  [[ "$output" == *"UPPER BOUND"* ]]
  [[ "$output" == *"seven_day  +4 points"* ]]
}

@test "diff across a rollover refuses to produce a number" {
  # Same percentages either side, different reset boundaries: subtracting these
  # yields +2, which looks entirely reasonable and is meaningless.
  row 7200 95 40 -3600 604800
  row 600 97 44 3600 604800
  run bash "$SCRIPT" diff --from -2h
  [ "$status" -eq 0 ]
  [[ "$output" == *"five_hour  INVALID"* ]]
  [[ "$output" == *"rolled over"* ]]
  if [[ "$output" == *"five_hour  +2"* ]]; then false; fi
  # The weekly window did not roll over, so it still answers.
  [[ "$output" == *"seven_day  +4 points"* ]]
}

@test "diff refuses a span with no reading before it starts" {
  row 600 17 44 3600 604800
  run bash "$SCRIPT" diff --from -3h
  [ "$status" -eq 0 ]
  [[ "$output" == *"INVALID: no reading of this window at or before"* ]]
  [[ "$output" == *"nothing to subtract from"* ]]
}

@test "diff reports no change when both ends land on the same reading" {
  row 7200 10 40 10800 604800
  run bash "$SCRIPT" diff --from -2h
  [ "$status" -eq 0 ]
  [[ "$output" == *"no change"* ]]
  [[ "$output" != *"points"* ]]
}

@test "a window that is null at one end is judged alone, not carried forward" {
  row 7200 10 40 10800 604800
  printf '{"at":"%s","five_hour":{"used_percentage":14,"resets_at":%s},"seven_day":null}\n' \
    "$(jq -rn --argjson t "$((NOW - 600))" '$t | todate')" "$((NOW + 10800))" \
    >> "$CLAUDE_USAGE_LOG"
  run bash "$SCRIPT" diff --from -2h
  [ "$status" -eq 0 ]
  [[ "$output" == *"five_hour  +4 points"* ]]
  # seven_day's last non-null reading is the opening one, so both ends resolve
  # to it — reported as no change, never as a drop to null.
  [[ "$output" == *"seven_day  no change"* ]]
}

@test "an explicit --to bounds the span at the reading in force then" {
  row 10800 10 40 14400 604800
  row 7200 20 50 14400 604800
  row 600 90 60 14400 604800
  run bash "$SCRIPT" diff --from -3h --to -1h
  [ "$status" -eq 0 ]
  [[ "$output" == *"five_hour  +10 points  (10% -> 20%)"* ]]
}

@test "history prints the last N readings oldest first" {
  row 1800 10 40 3600 604800
  row 1200 11 40 3600 604800
  row 600 12 40 3600 604800
  run bash "$SCRIPT" history -n 2
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ]
  [[ "$(printf '%s\n' "$output" | head -1)" == *"5h 11%"* ]]
  [[ "$(printf '%s\n' "$output" | tail -1)" == *"5h 12%"* ]]
}

@test "a time that cannot be read is an error, not a guessed instant" {
  row 600 12 40 3600 604800
  run bash "$SCRIPT" diff --from "last tuesday"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read"* ]]
}

@test "a reversed span is rejected" {
  row 600 12 40 3600 604800
  run bash "$SCRIPT" diff --from -1h --to -2h
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be earlier"* ]]
}

@test "a missing log is reported rather than answered" {
  run bash "$SCRIPT" now
  [ "$status" -ne 0 ]
  [[ "$output" == *"no usage log at"* ]]
}

@test "a corrupt log line fails closed instead of returning a partial answer" {
  row 600 12 40 3600 604800
  printf 'this is not json\n' >> "$CLAUDE_USAGE_LOG"
  run bash "$SCRIPT" now
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not parse"* ]]
}
