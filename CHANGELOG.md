# Changelog

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
