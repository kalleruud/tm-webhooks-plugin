#!/usr/bin/env python3
"""Test API parsing regressions, exhaustive field accounting and package isolation."""
import importlib.util
import json
import re
import subprocess
import tempfile
from unittest.mock import patch
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('generator', ROOT / 'scripts/generate-diagnostics.py')
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


class DiagnosticsTests(unittest.TestCase):
    def test_nested_enum_does_not_hide_following_members(self):
        fields, methods = gen.parse_members('''<div class="message-header">Members</div>
          <p class="docs-member"><span class="typename">UnnamedEnum</span> Mode</p>
          <article class="message"><div class="message-body">No enum names</div></article>
          <p class="docs-member"><span>const</span> <span class="typename">CGamePlayground@</span> CurrentPlayground</p>
          <div class="message-header">Inherited members <a>CMwNod</a></div>
          <p class="docs-member"><span class="typename">string</span> IdName</p>''')
        self.assertEqual(fields, [{'name': 'Mode', 'type': 'UnnamedEnum'}, {'name': 'CurrentPlayground', 'type': 'CGamePlayground@'}])
        self.assertEqual(methods, [])

    def test_generation_accounts_for_every_documented_field_and_is_reproducible(self):
        for game, (define, _) in gen.GAMES.items():
            inventory = json.loads((gen.OUT / f'{game}-api.json').read_text())
            existing = (gen.OUT / f'{game}.as').read_text()
            gen.generate(game, define, inventory)
            self.assertEqual(existing, (gen.OUT / f'{game}.as').read_text())
            names = {item['name'] for item in inventory if item['nod']}
            self.assertIn('CGamePlayground', names)
            self.assertIn('CTrackManiaPlayer' if game == 'turbo' else 'CSmPlayer', names)
            for item in inventory:
                if item['name'] not in names:
                    continue
                for member in item['members']:
                    key = item['name'] + '.' + member['name']
                    self.assertIn(f'c.BeginMember("{key}")', existing)
                    if gen.PRIVATE.search(member['name']):
                        self.assertIn(f'c.Skipped("{key}", "excluded"', existing)
            self.assertNotIn('Dev::', existing)

    def test_write_only_properties_never_generate_read_expressions(self):
        # These exact property reads were rejected by Turbo 1.29.14 before the
        # compiler asserted in ImplicitConversion. Check both games, even when a
        # particular property is absent from one game's documentation.
        for game in gen.GAMES:
            inventory = json.loads((gen.OUT / f'{game}-api.json').read_text())
            existing = (gen.OUT / f'{game}.as').read_text()
            for item in inventory:
                for member in item['members']:
                    key = item['name'] + '.' + member['name']
                    if key not in gen.WRITE_ONLY_MEMBERS:
                        continue
                    start = existing.index(f'void DiagnosticsRead_{item["name"]}(')
                    end = existing.index('\n}', start)
                    collector = existing[start:end]
                    self.assertIn(f'c.Skipped("{key}", "unsupported", "getter unavailable', collector)
                    self.assertNotRegex(collector, r'\bnode\.' + member['name'] + r'\b')

    def test_explicit_accessor_metadata_overrides_an_otherwise_readable_type(self):
        inventory = [{'name': 'CMwNod', 'nod': True, 'members': [
            {'name': 'WriteOnly', 'type': 'float', 'readable': False},
            {'name': 'Readable', 'type': 'float', 'readable': True},
        ]}]
        with tempfile.TemporaryDirectory() as directory, patch.object(gen, 'OUT', Path(directory)):
            gen.generate('test', 'TURBO', inventory)
            code = (Path(directory) / 'test.as').read_text()
            self.assertNotIn('node.WriteOnly', code)
            self.assertIn('getter unavailable', code)
            self.assertIn('node.Readable', code)

    def test_array_reads_checkpoint_and_trace_before_each_native_element(self):
        # A large native object array must not spend its entire cap in one
        # uninterruptible script loop. Check the generated loop itself.
        inventory = [{'name': 'CMwNod', 'nod': True, 'members': [
            {'name': 'Children', 'type': 'MwFastBuffer<CMwNod@>'},
        ]}]
        with tempfile.TemporaryDirectory() as directory, patch.object(gen, 'OUT', Path(directory)):
            gen.generate('test', 'TURBO', inventory)
            code = (Path(directory) / 'test.as').read_text()
            loop = code[code.index('for (uint i = 0;'):]
            self.assertLess(loop.index('c.Checkpoint()'), loop.index('node.Children[i]'))
            self.assertLess(loop.index('c.Trace("array-element"'), loop.index('node.Children[i]'))
            self.assertIn('c.BeginMember("CMwNod.Children")', code)

    def test_run_recorder_field_reads_match_each_games_documented_api(self):
        for game, source in [('turbo', 'RunTurbo.as'), ('next', 'RunNext.as')]:
            inventory = {item['name']: item for item in json.loads((gen.OUT / f'{game}-api.json').read_text())}
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
                self.assertFalse({name + '.' + field for field in used} & gen.WRITE_ONLY_MEMBERS)
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
                        self.assertIn('diagnostics/generated/turbo.as', names)
                        self.assertIn('diagnostics/generated/next.as', names)
                        self.assertIn('diagnostics/generated/turbo-api.json', names)
                        self.assertIn('diagnostics/generated/next-api.json', names)


if __name__ == '__main__':
    unittest.main()
