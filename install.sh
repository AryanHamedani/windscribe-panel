#!/bin/bash

# Install or update Windscribe for the Omarchy bar, dependencies included.
#
#   curl -fsSL https://raw.githubusercontent.com/AryanHamedani/windscribe-panel/main/install.sh | bash
#   bash install.sh DE        # bypass another country instead of Iran
#
# Safe to run again: it updates the plugin and fixes whatever is missing.

set -euo pipefail

ID=io.github.aryanhamedani.windscribe
REPO=https://github.com/AryanHamedani/windscribe-panel
DIR="$HOME/.config/omarchy/plugins/$ID"

step() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v omarchy >/dev/null || die "this plugin needs Omarchy 4 (https://omarchy.org): it runs inside the Omarchy shell"
for cmd in git jq curl python3 ping; do
  command -v "$cmd" >/dev/null || { step "Installing $cmd"; sudo pacman -S --needed --noconfirm "$(case $cmd in ping) echo iputils;; python3) echo python;; *) echo "$cmd";; esac)"; }
done

if [[ -d $DIR/.git ]]; then
  step "Updating the plugin"
  git -C "$DIR" pull --ff-only --quiet
elif [[ -e $DIR ]]; then
  die "$DIR exists but is not a git checkout; move it away and run this again"
else
  step "Adding the plugin"
  omarchy plugin add "$REPO" --enable --yes
fi
omarchy plugin enable "$ID" >/dev/null 2>&1 || true

# Not in the bar yet (enable places it once; a user may have taken it out).
if ! jq -e --arg id "$ID" '[.bar.layout[]?[]? | .id] | index($id)' "$HOME/.config/omarchy/shell.json" >/dev/null 2>&1; then
  step "Placing it in the bar, beside Network"
  omarchy bar put "$ID" --after omarchy.network 2>/dev/null || omarchy bar put "$ID" --section right
fi

exec "$DIR/bin/setup" "$@"
