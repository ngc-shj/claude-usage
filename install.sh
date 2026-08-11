#!/usr/bin/env bash
# Install the usage recorder into ~/.claude/usage/.
#
# The target is a directory of its own rather than ~/.claude/hooks/, which
# claude-code-config's installer treats as its own source of truth: it deletes
# any top-level *.sh there that its own hooks/ does not contain, so a copy of
# these scripts placed alongside them would disappear on that repo's next
# install. Only the statusLine command string ties the two repos together.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/.claude/usage"
LEGACY="$HOME/.claude/hooks"

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "ERROR: $command_name is required but is not on PATH." >&2
      exit 1
    }
  done
}

# jq and curl are hard requirements, not conveniences: without jq the status
# line renders but records nothing, which is the entire point of this repo, and
# without curl the poller cannot take a reading at all.
require_commands install jq curl awk

mkdir -p "$TARGET"

# Source-of-truth sync: a script that no longer exists here is removed, so a
# renamed one does not linger and keep running from the scheduler.
for installed in "$TARGET"/*.sh; do
  [ -e "$installed" ] || continue
  if [ ! -f "$SCRIPT_DIR/bin/$(basename "$installed")" ]; then
    rm -f "$installed"
    echo "  Removed stale script: $(basename "$installed")"
  fi
done

for source_file in "$SCRIPT_DIR"/bin/*.sh; do
  name="$(basename "$source_file")"
  install -m 0755 "$source_file" "$TARGET/$name"
  # A non-executable poller fails inside the scheduler, where nobody reads the
  # diagnostics until the log has already stopped growing.
  [ -x "$TARGET/$name" ] || {
    echo "ERROR: $TARGET/$name is not executable after install." >&2
    exit 1
  }
  echo "  Installed $name"
done

for legacy_name in statusline-usage.sh claude-usage-poll.sh; do
  if [ -e "$LEGACY/$legacy_name" ]; then
    echo "  NOTE: superseded copy still at $LEGACY/$legacy_name — it is now" \
         "managed here; claude-code-config's install.sh removes it."
  fi
done

cat <<EOF

Installed to $TARGET.

Point the status line at it in ~/.claude/settings.json:

  "statusLine": { "type": "command",
                  "command": "bash ~/.claude/usage/statusline-usage.sh" }

Then enable the five-minute background poller:

  bash $SCRIPT_DIR/scripts/install-usage-poller.sh
EOF
