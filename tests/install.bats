#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/install.sh"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TEST_HOME"
  export HOME="$TEST_HOME"
}

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

@test "installs every script in bin/ executable under ~/.claude/usage" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  for source_file in "$REPO_ROOT"/bin/*.sh; do
    name="$(basename "$source_file")"
    cmp -s "$source_file" "$TEST_HOME/.claude/usage/$name"
    [ -x "$TEST_HOME/.claude/usage/$name" ]
  done
}

@test "installs the skill tree into ~/.claude/skills" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed skill: usage-log"* ]]
  cmp -s "$REPO_ROOT/skills/usage-log/SKILL.md" \
    "$TEST_HOME/.claude/skills/usage-log/SKILL.md"
}

@test "a skill this repo does not ship is left alone" {
  # ~/.claude/skills is a namespace another installer writes into. Sweeping it
  # for entries missing from this repo would delete that installer's skills.
  mkdir -p "$TEST_HOME/.claude/skills/someone-elses"
  printf 'not ours\n' > "$TEST_HOME/.claude/skills/someone-elses/SKILL.md"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.claude/skills/someone-elses/SKILL.md" ]
  run cat "$TEST_HOME/.claude/skills/someone-elses/SKILL.md"
  [ "$output" = "not ours" ]
}

@test "a reinstall replaces a stale file inside the skill directory" {
  bash "$SCRIPT" >/dev/null
  printf 'stale\n' > "$TEST_HOME/.claude/skills/usage-log/leftover.md"

  bash "$SCRIPT" >/dev/null
  [ ! -e "$TEST_HOME/.claude/skills/usage-log/leftover.md" ]
  cmp -s "$REPO_ROOT/skills/usage-log/SKILL.md" \
    "$TEST_HOME/.claude/skills/usage-log/SKILL.md"
}

@test "the installed poller matches what the scheduler installer demands" {
  # scripts/install-usage-poller.sh refuses to schedule a poller that differs
  # from bin/, so an install.sh that landed a modified copy would leave the
  # two installers permanently disagreeing.
  bash "$SCRIPT" >/dev/null
  run cmp -s "$REPO_ROOT/bin/claude-usage-poll.sh" \
    "$TEST_HOME/.claude/usage/claude-usage-poll.sh"
  [ "$status" -eq 0 ]
}

@test "a reinstall over a world-readable copy tightens nothing it should not" {
  bash "$SCRIPT" >/dev/null
  chmod 777 "$TEST_HOME/.claude/usage/statusline-usage.sh"
  bash "$SCRIPT" >/dev/null
  run mode_of "$TEST_HOME/.claude/usage/statusline-usage.sh"
  [ "$output" = "755" ]
}

@test "a script no longer in bin/ is removed from the install" {
  bash "$SCRIPT" >/dev/null
  printf '#!/usr/bin/env bash\n' > "$TEST_HOME/.claude/usage/old-name.sh"
  chmod +x "$TEST_HOME/.claude/usage/old-name.sh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed stale script: old-name.sh"* ]]
  [ ! -e "$TEST_HOME/.claude/usage/old-name.sh" ]
}

@test "a missing jq fails the install instead of leaving a silent no-op logger" {
  # Without jq the status line still renders, so the failure would otherwise
  # surface only as a usage log that never grows.
  bin="$BATS_TEST_TMPDIR/nojq"; mkdir -p "$bin"
  for c in bash install curl awk basename dirname mkdir rm cat chmod; do
    [ -n "$(command -v "$c" || true)" ] && ln -sf "$(command -v "$c")" "$bin/$c"
  done
  [ ! -e "$bin/jq" ]

  run env PATH="$bin" "$(command -v bash)" "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq is required"* ]]
  [ ! -e "$TEST_HOME/.claude/usage/statusline-usage.sh" ]
}

@test "the superseded copy under ~/.claude/hooks is reported, not deleted" {
  # ~/.claude/hooks belongs to claude-code-config's installer. Deleting from it
  # here would make one repo's install silently mutate the other's tree.
  mkdir -p "$TEST_HOME/.claude/hooks"
  printf '#!/usr/bin/env bash\n' > "$TEST_HOME/.claude/hooks/statusline-usage.sh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"superseded copy still at"* ]]
  [ -e "$TEST_HOME/.claude/hooks/statusline-usage.sh" ]
}
