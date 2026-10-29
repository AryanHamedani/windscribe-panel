# Changelog

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
