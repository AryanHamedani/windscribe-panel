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


backend = load('backend', ROOT / 'backend.py')
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
        s = backend.parse_status(STATUS)
        self.assertEqual(s['state'], 'connected')
        self.assertEqual((s['city'], s['nickname']), ('Ashburn', 'Cloud City'))
        self.assertEqual(s['protocol'], 'WireGuard:443')
        self.assertEqual(s['usage'], '12.93 GB / Unlimited')

    def test_testing_star(self):
        self.assertEqual(backend.parse_status(STATUS.replace('Connect state', '*Connect state'))['state'], 'testing')

    def test_disconnected_with_firewall_is_blocked(self):
        text = STATUS.replace('Connected: Ashburn - Cloud City', 'Disconnected')
        self.assertEqual(backend.parse_status(text)['state'], 'blocked')
        text = text.replace('Always On', 'Off')
        self.assertEqual(backend.parse_status(text)['state'], 'disconnected')
        self.assertEqual(backend.parse_status(text)['location'], '')

    def test_connecting_and_signed_out(self):
        self.assertEqual(backend.parse_status(STATUS.replace('Connected: Ashburn - Cloud City', 'Connecting'))['state'], 'connecting')
        self.assertEqual(backend.parse_status(STATUS.replace('Logged in', 'Logged out'))['state'], 'signedOut')


class Locations(unittest.TestCase):
    def test_parse(self):
        rows = backend.parse_locations('Best Location - Tram (10 Gbps)\n'
                                       'US East - Tampa - Big Guava\n'
                                       'US Central - Dallas - BBQ (10 Gbps)\n')
        self.assertEqual([r['id'] for r in rows], ['BBQ', 'Big Guava'])
        self.assertEqual(rows[0], {'id': 'BBQ', 'city': 'Dallas', 'region': 'US Central', 'speed': '10 Gbps'})


class Hostnames(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(backend.hostname(' App.Example.IR. '), 'app.example.ir')
        self.assertEqual(backend.hostname('بانک.ir'), 'بانک.ir'.encode('idna').decode())
        self.assertTrue(backend.hostname('بانک.ir').startswith('xn--'))

    def test_invalid(self):
        for bad in ['', 'localhost', 'https://a.ir', '*.a.ir', 'a.ir/path', '1.2.3.4', 'a b.ir', '-a.ir']:
            with self.assertRaises(ValueError, msg=bad):
                backend.hostname(bad)

    def test_add_remove_and_limit(self):
        routes = ['1.2.3.0/24', 'a.ir']
        self.assertEqual(backend.change_domains(routes, 'add', 'b.ir'), routes + ['b.ir'])
        self.assertEqual(backend.change_domains(routes, 'add', 'a.ir'), routes)
        self.assertEqual(backend.change_domains(routes, 'remove', 'a.ir'), ['1.2.3.0/24'])
        full = ['h%d.ir' % i for i in range(50)]
        with self.assertRaises(ValueError):
            backend.change_domains(full, 'add', 'x.ir')


class Ini(unittest.TestCase):
    def test_read(self):
        prefs, routes = backend.read_preferences(CONFIG)
        self.assertEqual(prefs['domains'], ['snapp.ir'])
        self.assertEqual(prefs['rangeCount'], 2)
        self.assertEqual(len(routes), 3)

    def test_edit_keeps_everything_else(self):
        out = backend.edit_ini(CONFIG, {'AllowLANTraffic': 'true', 'Autoconnect': 'true'})
        self.assertIn('AllowLANTraffic=true\n', out)
        self.assertIn('Autoconnect=true\n[Networks]', out)
        self.assertEqual(out.replace('AllowLANTraffic=true\n', 'AllowLANTraffic=false\n').replace('Autoconnect=true\n', ''), CONFIG)

    def test_setting_whitelist(self):
        self.assertEqual(backend.setting_changes('Autoconnect', 'true'), {'Autoconnect': 'true'})
        self.assertEqual(backend.setting_changes('ManualConnectionProtocol', 'Stealth')['ConnectionMode'], 'Manual')
        self.assertEqual(backend.setting_changes('SplitTunnelingMode', 'Exclude'), {'SplitTunnelingMode': 'Exclude'})
        for key, value in [('SplitTunnelingMode', 'All'), ('Autoconnect', 'yes'), ('FirewallMode', 'Off'), ('ManualConnectionProtocol', 'IKEv2')]:
            with self.assertRaises(ValueError):
                backend.setting_changes(key, value)

    def test_mutate_writes_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'windscribe_cli.conf'
            path.write_text(CONFIG)
            with mock.patch.object(backend, 'CONFIG', path), mock.patch.object(backend, 'CONFIG_LOCK', Path(tmp) / 'lock'):
                backend.mutate(lambda p, r: {'SplitTunnelingRoutes': ', '.join(backend.change_domains(r, 'add', 'x.ir'))})
            self.assertIn('SplitTunnelingRoutes=2.144.0.0/14, 5.22.0.0/17, snapp.ir, x.ir\n', path.read_text())
            self.assertEqual(sorted(os.listdir(tmp)), ['lock', 'windscribe_cli.conf'])


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

    def test_write_routes_touches_one_line(self):
        out = refresher.write_routes(CONFIG, ['5.22.0.0/17', 'snapp.ir'])
        self.assertEqual(refresher.read_routes(out), ['5.22.0.0/17', 'snapp.ir'])
        self.assertEqual(out.count('\n'), CONFIG.count('\n'))

    def test_refresh_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, state = Path(tmp) / 'windscribe_cli.conf', Path(tmp) / 'state.json'
            path.write_text(CONFIG)
            with mock.patch.multiple(refresher, CONFIG=path, STATE=state, LOCK=Path(tmp) / 'lock'), \
                    mock.patch.object(refresher, 'fetch', return_value=self.payload(['2.144.0.0/14', '37.32.0.0/16'])):
                self.assertIn('updated', refresher.refresh('IR'))
                self.assertIn('unchanged', refresher.refresh('IR'))
            self.assertEqual(refresher.read_routes(path.read_text()), ['2.144.0.0/14', '37.32.0.0/16', 'snapp.ir'])
            self.assertEqual(json.loads(state.read_text())['country'], 'IR')
            self.assertTrue((Path(tmp) / 'windscribe_cli.conf.bak').exists())


if __name__ == '__main__':
    unittest.main()
