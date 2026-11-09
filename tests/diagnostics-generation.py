#!/usr/bin/env python3
"""Test API parsing regressions, exhaustive field accounting and package isolation."""
import importlib.util
import json
import subprocess
import tempfile
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
                    self.assertIn(f'c.member = "{key}"', existing)
                    if gen.PRIVATE.search(member['name']):
                        self.assertIn(f'c.Skipped("{key}", "excluded"', existing)
            self.assertNotIn('Dev::', existing)

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
