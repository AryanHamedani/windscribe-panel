"""Run with: python3 -m unittest discover -s tests"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


panel = load('windscribe_panel', ROOT / 'bin/windscribe-panel')
refresher = load('refresher', ROOT / 'bin/windscribe-split-refresh')

STATUS = """Internet connectivity: available
Login state: Logged in
Firewall state: Always On
Connect state: Connected: Ashburn - Cloud City
Protocol: WireGuard:443
VPN IP: 198.51.100.7
Data usage: 12.93 GB / Unlimited
"""

CONFIG = """[General]
Language=en

[Connection]
AllowLANTraffic=false
ConnectionMode=Auto
SplitTunnelingEnabled=true
SplitTunnelingRoutes=2.144.0.0/14, 5.22.0.0/17, snapp.ir
[Networks]
Home=trusted
"""


class Status(unittest.TestCase):
    def test_connected(self):
        s = panel.parse_status(STATUS)
        self.assertEqual(s['state'], 'connected')
        self.assertEqual((s['city'], s['nickname']), ('Ashburn', 'Cloud City'))
        self.assertEqual(s['protocol'], 'WireGuard:443')
        self.assertEqual(s['usage'], '12.93 GB / Unlimited')

    def test_testing_star(self):
        self.assertEqual(panel.parse_status(STATUS.replace('Connect state', '*Connect state'))['state'], 'testing')

    def test_disconnected_with_firewall_is_blocked(self):
        text = STATUS.replace('Connected: Ashburn - Cloud City', 'Disconnected')
        self.assertEqual(panel.parse_status(text)['state'], 'blocked')
        text = text.replace('Always On', 'Off')
        self.assertEqual(panel.parse_status(text)['state'], 'disconnected')
        self.assertEqual(panel.parse_status(text)['location'], '')

    def test_connecting_and_signed_out(self):
        self.assertEqual(panel.parse_status(STATUS.replace('Connected: Ashburn - Cloud City', 'Connecting'))['state'], 'connecting')
        self.assertEqual(panel.parse_status(STATUS.replace('Logged in', 'Logged out'))['state'], 'signedOut')


class Locations(unittest.TestCase):
    def test_parse(self):
        rows = panel.parse_locations('Best Location - Tram (10 Gbps)\n'
                                       'US East - Tampa - Big Guava\n'
                                       'US Central - Dallas - BBQ (10 Gbps)\n')
        self.assertEqual([r['id'] for r in rows], ['BBQ', 'Big Guava'])
        self.assertEqual(rows[0], {'id': 'BBQ', 'city': 'Dallas', 'region': 'US Central', 'speed': '10 Gbps'})


class Hostnames(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(panel.hostname(' App.Example.IR. '), 'app.example.ir')
        self.assertEqual(panel.hostname('بانک.ir'), 'بانک.ir'.encode('idna').decode())
        self.assertTrue(panel.hostname('بانک.ir').startswith('xn--'))

    def test_invalid(self):
        for bad in ['', 'localhost', 'https://a.ir', '*.a.ir', 'a.ir/path', '1.2.3.4', 'a b.ir', '-a.ir']:
            with self.assertRaises(ValueError, msg=bad):
                panel.hostname(bad)

    def test_add_remove_and_limit(self):
        routes = ['1.2.3.0/24', 'a.ir']
        self.assertEqual(panel.change_domains(routes, 'add', 'b.ir'), routes + ['b.ir'])
        self.assertEqual(panel.change_domains(routes, 'add', 'a.ir'), routes)
        self.assertEqual(panel.change_domains(routes, 'remove', 'a.ir'), ['1.2.3.0/24'])
        full = ['h%d.ir' % i for i in range(50)]
        with self.assertRaises(ValueError):
            panel.change_domains(full, 'add', 'x.ir')


class Ini(unittest.TestCase):
    def test_read(self):
        prefs, routes = panel.read_preferences(CONFIG)
        self.assertEqual(prefs['domains'], ['snapp.ir'])
        self.assertEqual(prefs['rangeCount'], 2)
        self.assertEqual(len(routes), 3)

    def test_edit_keeps_everything_else(self):
        out = panel.edit_ini(CONFIG, {'AllowLANTraffic': 'true', 'Autoconnect': 'true'})
        self.assertIn('AllowLANTraffic=true\n', out)
        self.assertIn('Autoconnect=true\n[Networks]', out)
        self.assertEqual(out.replace('AllowLANTraffic=true\n', 'AllowLANTraffic=false\n').replace('Autoconnect=true\n', ''), CONFIG)

    def test_setting_whitelist(self):
        self.assertEqual(panel.setting_changes('Autoconnect', 'true'), {'Autoconnect': 'true'})
        self.assertEqual(panel.setting_changes('ManualConnectionProtocol', 'Stealth')['ConnectionMode'], 'Manual')
        self.assertEqual(panel.setting_changes('SplitTunnelingMode', 'Exclude'), {'SplitTunnelingMode': 'Exclude'})
        for key, value in [('SplitTunnelingMode', 'All'), ('Autoconnect', 'yes'), ('FirewallMode', 'Off'), ('ManualConnectionProtocol', 'IKEv2')]:
            with self.assertRaises(ValueError):
                panel.setting_changes(key, value)

    def test_mutate_writes_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'windscribe_cli.conf'
            path.write_text(CONFIG)
            with mock.patch.object(panel, 'CONFIG', path), mock.patch.object(panel, 'CONFIG_LOCK', Path(tmp) / 'lock'):
                panel.mutate(lambda p, r: {'SplitTunnelingRoutes': ', '.join(panel.change_domains(r, 'add', 'x.ir'))})
            self.assertIn('SplitTunnelingRoutes=2.144.0.0/14, 5.22.0.0/17, snapp.ir, x.ir\n', path.read_text())
            self.assertEqual(sorted(os.listdir(tmp)), ['lock', 'windscribe_cli.conf'])


class Pings(unittest.TestCase):
    SERVERLIST = {'data': [{'name': 'US East', 'groups': [
        {'nick': 'Cloud City', 'link_speed': '10000', 'health': 6, 'ping_ip': '198.51.100.1'},
        {'nick': 'Sunny', 'link_speed': '1000', 'health': 13, 'ping_ip': ''},
        {'city': 'no nick'}]}]}

    def test_server_details(self):
        d = panel.server_details(self.SERVERLIST)
        self.assertEqual(d['Cloud City'], {'link': 10000, 'load': 6, 'pingIp': '198.51.100.1'})
        self.assertEqual(d['Sunny']['link'], 1000)
        self.assertEqual(len(d), 2)

    def test_ping_parse(self):
        out = '--- x ping statistics ---\n2 packets transmitted, 2 received\nrtt min/avg/max/mdev = 189.1/190.4/191.7/1.3 ms\n'
        with mock.patch.object(panel.subprocess, 'run', return_value=mock.Mock(stdout=out)):
            self.assertEqual(panel.ping_once('198.51.100.1'), 190)
        with mock.patch.object(panel.subprocess, 'run', return_value=mock.Mock(stdout='100% packet loss')):
            self.assertIsNone(panel.ping_once('198.51.100.1'))
        self.assertIsNone(panel.ping_once('not-an-ip; rm -rf /'))

    def run_pings(self, cache, connected, force=False):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            if cache is not None:
                (state / 'pings.json').write_text(json.dumps(cache))
            status = STATUS if connected else STATUS.replace('Connected: Ashburn - Cloud City', 'Disconnected')
            with mock.patch.object(panel, 'STATE_DIR', state), \
                    mock.patch.object(panel, 'cli', return_value=status), \
                    mock.patch.object(panel, 'cached_json', return_value=self.SERVERLIST), \
                    mock.patch.object(panel, 'ping_once', return_value=42):
                return panel.pings(force)

    def ago(self, seconds):
        from datetime import datetime, timedelta, timezone
        return (datetime.now(timezone.utc) - timedelta(seconds=seconds)).isoformat()

    def test_fresh_cache_is_reused(self):
        cache = {'pings': {'x': 1}, 'measured': self.ago(60), 'tunnel': True}
        self.assertEqual(self.run_pings(cache, connected=True), cache)

    def test_direct_measurement_beats_tunnel(self):
        # An hour-old direct measurement is kept while connected, rather than re-measured through the tunnel.
        cache = {'pings': {'x': 1}, 'measured': self.ago(3600), 'tunnel': False}
        self.assertEqual(self.run_pings(cache, connected=True), cache)
        # Disconnected, the same stale cache is measured again, directly.
        fresh = self.run_pings(cache, connected=False)
        self.assertEqual(fresh['pings'], {'Cloud City': 42})
        self.assertFalse(fresh['tunnel'])

    def test_force_and_tunnel_flag(self):
        cache = {'pings': {'x': 1}, 'measured': self.ago(60), 'tunnel': False}
        result = self.run_pings(cache, connected=True, force=True)
        self.assertTrue(result['tunnel'])
        self.assertEqual(result['pings'], {'Cloud City': 42})


class BarFrontEnd(unittest.TestCase):
    def test_states(self):
        for raw, shown in [('connected', 'connected'), ('testing', 'connecting'), ('connecting', 'connecting'),
                           ('blocked', 'off'), ('disconnected', 'unprotected'), ('signedOut', 'signedOut')]:
            self.assertEqual(panel.bar_state({'state': raw}), shown)

    def test_waybar_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'windscribe_cli.conf'
            path.write_text(CONFIG)
            with mock.patch.object(panel, 'CONFIG', path), mock.patch.object(panel, 'cli', return_value=STATUS), \
                    mock.patch.object(panel, 'STATE', Path(tmp) / 'none'), mock.patch.object(panel, 'LEGACY_STATE', Path(tmp) / 'none'):
                out = panel.waybar()
        self.assertEqual((out['text'], out['alt'], out['class']), ('Ashburn', 'connected', 'connected'))
        self.assertIn('198.51.100.7', out['tooltip'])
        self.assertIn('2 ranges · 1 hosts', out['tooltip'])

    def test_waybar_survives_a_dead_cli(self):
        with mock.patch.object(panel, 'cli', side_effect=RuntimeError('windscribe-cli <is> not installed')):
            out = panel.waybar()
        self.assertEqual(out['class'], 'unknown')
        self.assertIn('&lt;is&gt;', out['tooltip'])  # pango-escaped

    def test_choose_uses_custom_launcher(self):
        with mock.patch.dict(os.environ, {'WINDSCRIBE_PANEL_MENU': 'sed -n 2p'}):
            self.assertEqual(panel.choose('x', ['first', 'second', 'third']), 'second')
        with mock.patch.dict(os.environ, {'WINDSCRIBE_PANEL_MENU': 'false'}):
            self.assertIsNone(panel.choose('x', ['first']))  # exit 1: dismissed

    def test_custom_launcher_gets_its_prompt(self):
        # The last argument is the prompt flag; the prompt must follow it.
        calls = []
        with mock.patch.dict(os.environ, {'WINDSCRIBE_PANEL_MENU': 'rofi -dmenu -i -p'}), \
                mock.patch.object(panel.subprocess, 'run', side_effect=lambda cmd, **kw: calls.append(cmd) or mock.Mock(returncode=1, stdout='', stderr='')):
            panel.choose('Location', ['a'])
        self.assertEqual(calls[0], ['rofi', '-dmenu', '-i', '-p', 'Location '])

    def test_launcher_fault_is_reported(self):
        with mock.patch.dict(os.environ, {'WINDSCRIBE_PANEL_MENU': 'sh -c "echo bad flag >&2; exit 2"'}):
            with self.assertRaises(RuntimeError) as caught:
                panel.choose('x', ['a'])
        self.assertIn('bad flag', str(caught.exception))

    def test_padded_labels_survive_a_real_launcher(self):
        # Location rows are padded for alignment; the launcher hands back the
        # line however it trims it. Nothing mocked: a real command picks.
        ran = []
        with mock.patch.dict(os.environ, {'WINDSCRIBE_PANEL_MENU': 'sed -n 2p'}):
            panel.pick('x', [('      Best location', lambda: ran.append('best')),
                             ('  190 ms  Ashburn · Cloud City', lambda: ran.append('ashburn'))])
        self.assertEqual(ran, ['ashburn'])

    def test_missing_config_is_explained(self):
        with mock.patch.object(panel, 'CONFIG', Path('/nonexistent/windscribe_cli.conf')), \
                mock.patch.object(panel, 'cli', return_value=STATUS):
            out = panel.waybar()
        self.assertIn('windscribe-cli status once', out['tooltip'])

    def test_blank_menu_variable_falls_back(self):
        with mock.patch.dict(os.environ, {'WINDSCRIBE_PANEL_MENU': '   '}), \
                mock.patch.object(panel.shutil, 'which', return_value=None):
            with self.assertRaises(RuntimeError) as caught:
                panel.choose('x', ['a'])
        self.assertIn('No menu launcher', str(caught.exception))

    def test_pick_runs_the_chosen_action(self):
        ran = []
        with mock.patch.object(panel, 'choose', return_value='b'):
            panel.pick('x', [('a', lambda: ran.append('a')), ('b', lambda: ran.append('b'))])
        self.assertEqual(ran, ['b'])


class Refresher(unittest.TestCase):
    def payload(self, v4, v6=()):
        return {'status': 'ok', 'data': {'resources': {'ipv4': list(v4), 'ipv6': list(v6)}}}

    def test_validates_and_collapses(self):
        out = refresher.validated_ranges(self.payload(['5.22.0.0/18', '5.22.64.0/18'], ['2a01:5ec0::/29']))
        self.assertEqual(out, ['5.22.0.0/17', '2a01:5ec0::/29'])

    def test_rejects_unsafe(self):
        for bad in (['10.0.0.0/8'], ['0.0.0.0/0'], ['1.0.0.0/7'], []):
            with self.assertRaises(ValueError, msg=bad):
                refresher.validated_ranges(self.payload(bad))
        with self.assertRaises(ValueError):
            refresher.validated_ranges({'status': 'error'})

    def test_merge_keeps_user_entries(self):
        current = ['2.144.0.0/14', '9.9.9.0/24', 'snapp.ir']
        # 9.9.9.0/24 was not in the last country list, so the user added it.
        merged = refresher.merge_routes(current, ['2.144.0.0/14', '5.22.0.0/17'], ['2.144.0.0/14', '1.1.1.0/24'])
        self.assertEqual(merged, ['2.144.0.0/14', '5.22.0.0/17', '9.9.9.0/24', 'snapp.ir'])
        # No record of the last list: every range is treated as ours.
        self.assertEqual(refresher.merge_routes(current, ['5.22.0.0/17'], None), ['5.22.0.0/17', 'snapp.ir'])

    def test_merge_always_keeps_tailscale(self):
        ts = refresher.TAILSCALE_RANGES
        # Fresh machine, no state: the ranges survive and come once, after the country list.
        merged = refresher.merge_routes(['100.64.0.0/10', 'snapp.ir'], ['5.22.0.0/17'], None, ts)
        self.assertEqual(merged, ['5.22.0.0/17', *ts, 'snapp.ir'])
        # Already in the list as a user entry: still only once.
        merged = refresher.merge_routes(['5.22.0.0/17', *ts], ['5.22.0.0/17'], ['5.22.0.0/17'], ts)
        self.assertEqual(merged, ['5.22.0.0/17', *ts])
        # Tailscale gone: ranges we wrote last time are ours, so they are removed.
        merged = refresher.merge_routes(['5.22.0.0/17', *ts, 'snapp.ir'], ['5.22.0.0/17'], ['5.22.0.0/17'], [], ts)
        self.assertEqual(merged, ['5.22.0.0/17', 'snapp.ir'])

    def test_legacy_state_is_read(self):
        # State written by 1.1 under the old folder name still marks which ranges are ours.
        with tempfile.TemporaryDirectory() as tmp:
            new, old = Path(tmp) / 'windscribe-panel/s.json', Path(tmp) / 'omarchy-windscribe/s.json'
            old.parent.mkdir()
            old.write_text(json.dumps({'country': 'IR', 'ranges': ['2.144.0.0/14']}))
            with mock.patch.multiple(refresher, STATE=new, LEGACY_STATE=old):
                self.assertEqual(refresher.load_state()['ranges'], ['2.144.0.0/14'])
                new.parent.mkdir()
                new.write_text(json.dumps({'ranges': ['5.22.0.0/17']}))
                self.assertEqual(refresher.load_state()['ranges'], ['5.22.0.0/17'])

    def test_write_routes_touches_one_line(self):
        out = refresher.write_routes(CONFIG, ['5.22.0.0/17', 'snapp.ir'])
        self.assertEqual(refresher.read_routes(out), ['5.22.0.0/17', 'snapp.ir'])
        self.assertEqual(out.count('\n'), CONFIG.count('\n'))

    def test_refresh_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, state = Path(tmp) / 'windscribe_cli.conf', Path(tmp) / 'state.json'
            path.write_text(CONFIG)
            with mock.patch.multiple(refresher, CONFIG=path, STATE=state, LOCK=Path(tmp) / 'lock'), \
                    mock.patch.object(refresher, 'fetch', return_value=self.payload(['2.144.0.0/14', '37.32.0.0/16'])), \
                    mock.patch.object(refresher, 'tailscale_enabled', return_value=False) as enabled:
                self.assertIn('updated', refresher.refresh('IR'))
                self.assertIn('unchanged', refresher.refresh('IR'))
                self.assertEqual(refresher.read_routes(path.read_text()), ['2.144.0.0/14', '37.32.0.0/16', 'snapp.ir'])
                # tailscaled enabled: its ranges are added once and stay on the next refresh.
                enabled.return_value = True
                refresher.refresh('IR')
                self.assertIn('unchanged', refresher.refresh('IR'))
                self.assertEqual(refresher.read_routes(path.read_text()),
                                 ['2.144.0.0/14', '37.32.0.0/16', *refresher.TAILSCALE_RANGES, 'snapp.ir'])
                # --drop-tailscale (setup --uninstall) takes them out without a fetch.
                self.assertIn('removed', refresher.drop_tailscale())
                self.assertEqual(refresher.read_routes(path.read_text()), ['2.144.0.0/14', '37.32.0.0/16', 'snapp.ir'])
                self.assertEqual(json.loads(state.read_text())['always'], [])
                # A range the user listed by hand is not ours to drop.
                path.write_text(refresher.write_routes(path.read_text(), ['100.64.0.0/10', 'snapp.ir']))
                refresher.drop_tailscale()
                self.assertIn('100.64.0.0/10', refresher.read_routes(path.read_text()))
            self.assertEqual(json.loads(state.read_text())['country'], 'IR')
            self.assertTrue((Path(tmp) / 'windscribe_cli.conf.bak').exists())

    def test_tailscale_ranges_need_the_fail_closed_drop_in(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(refresher.shutil, 'which', return_value='/usr/bin/tailscale'), \
                mock.patch.object(refresher.subprocess, 'run', return_value=mock.Mock(returncode=0)):
            with mock.patch.object(refresher, 'TS_DROPIN', Path(tmp) / 'missing.conf'):
                self.assertFalse(refresher.tailscale_enabled())
            dropin = Path(tmp) / 'present.conf'
            dropin.write_text('')
            with mock.patch.object(refresher, 'TS_DROPIN', dropin):
                self.assertTrue(refresher.tailscale_enabled())

    def test_refresh_ranges_takes_only_a_country_code(self):
        for bad in (['refresh-ranges', '--drop-tailscale'], ['refresh-ranges', 'IRN']):
            with mock.patch.object(panel.subprocess, 'run') as run, self.assertRaises(ValueError, msg=bad):
                panel.dispatch(bad)
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
