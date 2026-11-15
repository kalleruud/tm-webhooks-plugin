#!/usr/bin/env python3
"""Check recorder field reads against the documented API and production isolation."""
import importlib.util
import json
import re
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('refresh', ROOT / 'scripts/refresh-openplanet-api.py')
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)


class DiagnosticsRecorderTests(unittest.TestCase):
    def test_nested_enum_does_not_hide_following_members(self):
        fields, methods = refresh.parse_members('''<div class="message-header">Members</div>
          <p class="docs-member"><span class="typename">UnnamedEnum</span> Mode</p>
          <article class="message"><div class="message-body">No enum names</div></article>
          <p class="docs-member"><span>const</span> <span class="typename">CGamePlayground@</span> CurrentPlayground</p>
          <div class="message-header">Inherited members <a>CMwNod</a></div>
          <p class="docs-member"><span class="typename">string</span> IdName</p>''')
        self.assertEqual(fields, [{'name': 'Mode', 'type': 'UnnamedEnum'}, {'name': 'CurrentPlayground', 'type': 'CGamePlayground@'}])
        self.assertEqual(methods, [])

    def test_run_recorder_field_reads_match_each_games_documented_api(self):
        # No game runtime is available in CI; this catches misspelled or
        # wrong-game members before an Openplanet compile does.
        for game, source in [('turbo', 'RunTurbo.as'), ('next', 'RunNext.as')]:
            inventory = {item['name']: item for item in json.loads((refresh.OUT / f'{game}-api.json').read_text())}

            def members(name):
                item = inventory[name]
                own = {field['name'] for field in item['members']}
                return own | members(item['base']) if item['base'] else own

            bindings = {'player': 'CTrackManiaPlayer' if game == 'turbo' else 'CSmPlayer',
                        'event': 'CTmRaceRulesEvent' if game == 'turbo' else 'CSmArenaRulesEvent',
                        'score': 'CTmRaceRulesScore' if game == 'turbo' else 'CSmArenaScore',
                        'script': 'CSmScriptPlayer', 'tmScore': 'CTrackManiaScore',
                        'modeRules': 'CTrackManiaRaceRules' if game == 'turbo' else 'CSmArenaRulesMode'}
            code = (ROOT / 'diagnostics' / source).read_text()
            for variable, name in bindings.items():
                if name not in inventory:
                    continue
                used = set(re.findall(r'\b' + variable + r'\.(\w+)', code))
                self.assertFalse(used - members(name), f'{game}: {name} has no {used - members(name)}')
            common = (ROOT / 'diagnostics' / 'RunRecorder.as').read_text()
            for variable, name in [('user', 'CGamePlayerInfo'), ('map', 'CGameCtnChallenge')]:
                used = set(re.findall(r'\b' + variable + r'\.(\w+)', common))
                self.assertFalse(used - members(name), f'{game}: {name} has no {used - members(name)}')

    def test_production_has_no_diagnostics_source_or_define(self):
        with tempfile.TemporaryDirectory() as directory:
            for profile, filename in [('all', 'tm-webhooks.op'), ('diagnostics', 'tm-webhooks-diagnostics.op')]:
                subprocess.run(['bash', 'scripts/build-op.sh', profile, directory], cwd=ROOT, check=True)
                with zipfile.ZipFile(Path(directory) / filename) as archive:
                    names = archive.namelist()
                    manifest = archive.read('info.toml').decode()
                    if profile == 'all':
                        self.assertFalse(any('diagnostics' in name.lower() for name in names))
                        self.assertNotIn('DIAGNOSTICS', manifest)
                        for name in names:
                            if name.endswith('.as'):
                                self.assertNotIn('Diagnostics', archive.read(name).decode())
                    else:
                        self.assertIn('defines = ["DIAGNOSTICS"]', manifest)
                        self.assertIn('DiagnosticsTick();', archive.read('src/Main.as').decode())
                        self.assertIn('diagnostics/RunRecorder.as', names)
                        self.assertFalse(any('generated' in name for name in names))
                        settings = archive.read('diagnostics/Settings.as').decode()
                        self.assertEqual(len(re.findall(r'^\[Setting ', settings, re.M)), 2)
                        self.assertNotIn('Authorization', archive.read('diagnostics/Harness.as').decode())


if __name__ == '__main__':
    unittest.main()
