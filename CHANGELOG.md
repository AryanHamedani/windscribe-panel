# Changelog

## 2.1.3 (2026-11-05)

- `bin/setup` runs its `ip rule` commands as argument arrays instead of
  word-split command strings; shellcheck passes again, so CI is green.

## 2.1.2 (2026-11-05)

- Security: a refresh keeps Tailscale's ranges in the route list only while
  `bin/setup`'s drop-in is in place. Enabling Tailscale after setup no longer
  opens the ranges without the `unreachable` rule that keeps them fail closed.
- Security: `bin/setup` refuses to install a `windscribe-cli` package that
  GitHub gives no sha256 for, instead of installing it on HTTPS trust alone.
- `setup --uninstall` always takes out the Tailscale ranges a refresh added,
  and only those (a range you listed yourself stays), and removes the empty
  drop-in folder.
- The cached server list and pings are written atomically, so opening the
  panel no longer fails when two refreshes race.
- `refresh-ranges` accepts only a two-letter country code.
- README: install from the Omarchy plugin marketplace; uninstall on Omarchy
  runs `setup --uninstall` first. The Omarchy screenshot is the root
  `preview.png`.

## 2.1.1 (2026-11-02)

- Security: the Tailscale ranges now fail closed. A non-peer address in
  `100.64.0.0/10`, or any of the range while tailscaled is stopped, hit
  Windscribe's bypass route and left by the router outside the VPN; an
  `unreachable` rule (priority 5201) now catches it, and the rules stay when
  tailscaled stops.
- The ranges are kept only while tailscaled is enabled (not just installed),
  are recorded in the state file so a later refresh removes them, and
  `bin/setup --uninstall` takes them out of the route list.

## 2.1.0 (2026-11-02)

- **Tailscale works beside Windscribe and its firewall.** With `tailscale`
  installed, the split-tunnel refresh always keeps `100.64.0.0/10` and
  `fd7a:115c:a1e0::/48` in the route list (also on a fresh machine with no
  saved state), and `bin/setup` adds a `tailscaled.service` drop-in that
  routes those ranges to Tailscale's table ahead of Windscribe's rules.
  `bin/setup --uninstall` takes the drop-in and the rule back out.

## 2.0.1 (2026-10-30)

- Security: the windscribe-cli lock no longer falls back to a world-writable
  `/tmp` when `XDG_RUNTIME_DIR` is unset, where another user could plant a
  symlink; it uses the private state folder instead.

## 2.0.0 (2026-10-30)

Windscribe Panel is no longer tied to one desktop.

- **Waybar front end** for Hyprland, Sway, niri, river and other wlroots
  compositors: a status icon per state, a tooltip with location, IP,
  protocol, firewall, data and bypass, and menus for locations (fastest
  first), settings and connect/disconnect, in fuzzel, wofi, rofi, tofi,
  bemenu or any dmenu-style launcher (`WINDSCRIBE_PANEL_MENU`).
- **One program**, `bin/windscribe-panel` (was `backend.py`), behind both
  front ends; the Omarchy panel moved to `omarchy/`.
- **Any distribution**: `bin/setup` installs dependencies and the official
  `windscribe-cli` package with pacman, apt, dnf or zypper, for x86_64 and,
  where Windscribe publishes it, aarch64.
- `install.sh` picks the front end for your desktop (`--waybar` to choose).
- The Omarchy panel refreshes the last country fetched by default, like the
  menus, instead of always Iran.
- Fixed: a launcher command ending in its prompt flag got no prompt, and
  launcher failures were silently treated as a dismissed menu.

Upgrading on Omarchy needs nothing: `install.sh` or `git pull` as before.

## 1.2.0 (2026-10-30)

- The repository is now `AryanHamedani/windscribe-panel` (the old address
  redirects). The refresh timer is `windscribe-split-refresh.timer` and its
  state lives in `~/.local/state/windscribe-panel/`; `bin/setup` removes the
  old timer, and state saved by 1.1 is still read until the next refresh.

## 1.1.2 (2026-10-30)

- Fixed: signing in from the `curl … | bash` installer read the script
  instead of the keyboard; the prompt now reads the terminal.

## 1.1.1 (2026-10-30)

- Fixed: a dependency check piped into `grep -q` could misfire under
  `pipefail` and redo work that was already done.

## 1.1.0 (2026-10-30)

- Locations show ping, link speed and load, sorted fastest first; a toggle
  switches to grouping by region. Pings measured while disconnected are
  preferred over tunnelled ones, and tunnelled ones are labelled.
- One-command install and update (`install.sh`), and `bin/setup` now installs
  its dependencies, `windscribe-cli` included: the official Arch package from
  Windscribe's GitHub releases, verified against its sha256.
- The bar and hero use Windscribe's own badge, filled when connected and
  outlined when off, in place of a struck-through outline.
- Fixed: the left border of the search field, buttons and rows disappeared at
  fractional display scales (Qt's clip shaves the first pixel column).
- Fixed: reopening the panel kept the old search and scroll position.

## 1.0.0 (2026-10-30)

First public release.

- Bar icon that shows the tunnel at a glance: plain when connected, struck
  through when off, urgent when off with no firewall.
- Popup with the connected location, VPN IP (click to copy), data used,
  firewall, DNS, LAN and bypass state.
- Searchable location list grouped by region, with the current region and any
  `pinnedRegions` first. Arrow keys and Enter connect from the search field.
- Connection page: auto-connect, protocol (Auto, WireGuard, Stealth,
  WStunnel, UDP, TCP), censorship circumvention and AmneziaWG presets, LAN
  traffic.
- Split tunneling page: a country's IP ranges plus up to 50 hostnames bypass
  the tunnel. Ranges come from RIPEstat and refresh weekly.
- `bin/setup` installs the weekly refresh as a systemd user timer.
- Disconnect asks first, and says what will happen to your traffic.
