#!/bin/bash

# Install or update Windscribe Panel, dependencies included.
#
#   curl -fsSL https://raw.githubusercontent.com/AryanHamedani/windscribe-panel/main/install.sh | bash
#   … | bash -s -- DE          bypass another country instead of Iran
#   … | bash -s -- --waybar    use the Waybar front end even on Omarchy
#
# On Omarchy it installs the shell panel; anywhere else, the windscribe-panel
# command and a Waybar module. Safe to run again: it updates and fixes
# whatever is missing.

set -euo pipefail

# Everything runs from main, called on the last line: under `curl | bash` a
# download cut short runs nothing, and no child can read the script as input.
main() {

REPO=https://github.com/AryanHamedani/windscribe-panel
OMARCHY_ID=io.github.aryanhamedani.windscribe

step() { printf '\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

front=auto
setup_args=()
for arg in "$@"; do
  case $arg in
  --waybar) front=waybar ;;
  *) setup_args+=("$arg") ;;
  esac
done
if [[ $front == auto ]]; then
  if command -v omarchy >/dev/null && [[ -d $HOME/.config/omarchy ]]; then front=omarchy; else front=waybar; fi
fi

command -v git >/dev/null || die "git is needed to install; install it and run this again"

# Clone, or fast-forward an existing clone.
checkout() {
  if [[ -d $1/.git ]]; then
    step "Updating $1"
    git -C "$1" pull --ff-only --quiet
  elif [[ -e $1 ]]; then
    die "$1 exists but is not a git checkout; move it away and run this again"
  else
    step "Cloning into $1"
    git clone --quiet "$REPO" "$1"
  fi
}

if [[ $front == omarchy ]]; then
  dir="$HOME/.config/omarchy/plugins/$OMARCHY_ID"
  if [[ -d $dir/.git ]]; then
    checkout "$dir"
  else
    [[ ! -e $dir ]] || die "$dir exists but is not a git checkout; move it away and run this again"
    step "Adding the Omarchy shell plugin"
    omarchy plugin add "$REPO" --enable --yes
  fi
  omarchy plugin enable "$OMARCHY_ID" >/dev/null 2>&1 || true
  if ! jq -e --arg id "$OMARCHY_ID" '[.bar.layout[]?[]? | .id] | index($id)' "$HOME/.config/omarchy/shell.json" >/dev/null 2>&1; then
    step "Placing it in the bar, beside Network"
    omarchy bar put "$OMARCHY_ID" --after omarchy.network 2>/dev/null || omarchy bar put "$OMARCHY_ID" --section right
  fi
else
  dir="${XDG_DATA_HOME:-$HOME/.local/share}/windscribe-panel"
  checkout "$dir"
  step "Linking the windscribe-panel command into ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$dir/bin/windscribe-panel" "$HOME/.local/bin/windscribe-panel"
  ln -sfn "$dir/bin/windscribe-split-refresh" "$HOME/.local/bin/windscribe-split-refresh"

  waybar="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"
  step "Adding the Waybar module to $waybar"
  mkdir -p "$waybar"
  # A bar started by the compositor may not have ~/.local/bin on its PATH.
  sed "s#\"windscribe-panel #\"$HOME/.local/bin/windscribe-panel #g" "$dir/waybar/module.jsonc" >"$waybar/windscribe-panel.jsonc"
  cp "$dir/waybar/style.css" "$waybar/windscribe-panel.css"

  if ! command -v fuzzel >/dev/null && ! command -v wofi >/dev/null && ! command -v rofi >/dev/null \
    && ! command -v tofi >/dev/null && ! command -v bemenu >/dev/null; then
    step "Installing fuzzel, for the location and settings menus"
    if command -v pacman >/dev/null; then sudo pacman -S --needed --noconfirm fuzzel
    elif command -v apt-get >/dev/null; then sudo apt-get update && sudo apt-get install -y fuzzel
    elif command -v dnf >/dev/null; then sudo dnf install -y fuzzel
    elif command -v zypper >/dev/null; then sudo zypper -n install fuzzel
    else note "Install a dmenu-style launcher (fuzzel, wofi, rofi, tofi or bemenu) for the menus"; fi
  fi
fi

"$dir/bin/setup" "${setup_args[@]}"

if [[ $front == waybar ]]; then
  cat <<EOF

To show it, add two lines to your Waybar config (~/.config/waybar/config.jsonc):

    "include": ["~/.config/waybar/windscribe-panel.jsonc"],
    "modules-right": ["custom/windscribe", ...your other modules],

and one to the top of ~/.config/waybar/style.css:

    @import "windscribe-panel.css";

then restart Waybar. Not on Waybar? Any bar that runs a command and reads
JSON can use "windscribe-panel waybar"; see the README.
EOF
fi
}

main "$@"
