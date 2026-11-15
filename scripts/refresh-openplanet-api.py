#!/usr/bin/env python3
"""Refresh the Openplanet API inventories used to check run recorder field reads.

Writes tests/fixtures/openplanet-api/<game>-api.json from the public type pages.
Uses only the Python standard library.
"""
import argparse
import concurrent.futures
import html
import json
import re
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'tests' / 'fixtures' / 'openplanet-api'
GAMES = {'turbo': 'CTrackMania', 'next': 'CTrackMania'}
def plain(value):
    return html.unescape(re.sub('<[^>]+>', '', value)).strip()


def download(game, name):
    url = f'https://{game}.openplanet.dev/lookup/{name}'
    with urllib.request.urlopen(url, timeout=45) as response:
        page = response.read().decode()
    if 'Permalink' not in page or f'>{name}</h1>' not in page:
        raise ValueError(f'No type documentation: {url}')
    members, methods = parse_members(page)
    return {'name': name, 'url': url, 'members': members, 'methods': methods,
            'nod': name == 'CMwNod' or '/CMwNod' in page,
            'children': re.findall(r'<a[^>]+>(C\w+)</a>', (re.findall(r'Inherited by</h3>(.*?)</div>', page, re.S) or [''])[0]) if name != 'CMwNod' else [],
            'base': (re.findall(r'Inherits from\s*.*?<a[^>]+>(\w+)</a>', page, re.S) or [None])[0]}


def parse_members(page):
    # Nested enum panels are also <article> elements. Track section headings,
    # rather than splitting articles, so fields after an enum are not lost.
    members, methods, section = [], [], ''
    tokens = re.finditer(r'<div class="message-header">(.*?)</div>|<p class="docs-member">(.*?)</p>', page, re.S)
    for token in tokens:
        if token[1] is not None:
            section = plain(token[1])
            continue
        text = plain(token[2])
        if section == 'Methods':
            methods.append(text)
        elif section == 'Members':
            text = re.sub(r'^const\s+', '', text)
            match = re.match(r'(.+?)\s+([A-Za-z_]\w*)(?:\s|$)', text, re.S)
            if match:
                members.append({'name': match[2], 'type': re.sub(r'\s+', '', match[1])})
    return members, methods


def refresh(game, root):
    found, pending = {}, {root}
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        while pending:
            batch = sorted(pending - found.keys())
            pending = set()
            for value in pool.map(lambda name: download(game, name), batch):
                found[value['name']] = value
                pending.update(value['children'])
                if value['base']:
                    pending.add(value['base'])
                for member in value['members']:
                    pending.update(re.findall(r'\b(C\w+)@', member['type']))
            pending -= found.keys()
            print(game, len(found), 'types;', len(pending), 'pending', flush=True)
    return [found[name] for name in sorted(found)]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', choices=['all', 'turbo', 'next'], default='all')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for game, root in GAMES.items():
        if args.game in ('all', game):
            (OUT / f'{game}-api.json').write_text(json.dumps(refresh(game, root), indent=2) + '\n')
