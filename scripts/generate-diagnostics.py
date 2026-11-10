#!/usr/bin/env python3
"""Refresh public API inventories (--refresh) and generate typed read-only collectors.

No game method calls or memory-offset access is generated. Uses only Python stdlib.
"""
import argparse
import concurrent.futures
import hashlib
import html
import json
import re
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'diagnostics' / 'generated'
GAMES = {'turbo': ('TURBO', 'CTrackMania'), 'next': ('TMNEXT', 'CTrackMania')}


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


PRIVATE = re.compile(r'token|password|secret|authorization|credential|cookie|login|account|profile|username|nickname|author|buddy|buddies|friend|url|folder|path|directory|filename|chat|message|email|address|ipaddress', re.I)
# The public type pages list setters alongside readable fields without exposing
# accessor flags. Turbo 1.29.14's compiler log confirms these seven have no get
# accessor. Skip them in both games until runtime type metadata proves otherwise;
# try/catch cannot protect a property expression that fails at compile time.
WRITE_ONLY_MEMBERS = frozenset({
    'CAudioScriptMusic.Dbg_ForceIntensity',
    'CAudioScriptMusic.Dbg_ForceSequential',
    'CAudioScriptMusic.Dbg_ForceRandom',
    'CAudioScriptMusic.UseNewImplem',
    'CGameSafeFrame.Position',
    'CPlugSpline3D.Translate',
    'CSmPlayer.ForceLinearHue',
})


PRIMITIVES = {'bool', 'int', 'uint', 'int8', 'uint8', 'int16', 'uint16', 'int64', 'uint64', 'float', 'double', 'string', 'wstring', 'MwId', 'vec2', 'vec3', 'vec4', 'int2', 'int3', 'nat2', 'nat3', 'quat', 'iso4', 'mat3', 'mat4'}


def expression(typ, expr, names):
    if typ.endswith('@') and typ[:-1] in names:
        return f'c.Link({expr}, depth + 1)'
    if typ == 'MwId':
        return f'Json::Value({expr}.Value)'
    if typ == 'wstring':
        return f'c.Text(string({expr}))'
    if typ == 'string':
        return f'c.Text({expr})'
    if typ in {'bool', 'int', 'uint', 'int8', 'uint8', 'int16', 'uint16', 'int64', 'uint64'}:
        # Stringify 64-bit integers to preserve exact values in JSON consumers.
        return f'Json::Value(tostring({expr}))' if typ.endswith('64') else f'Json::Value({expr})'
    if typ in {'float', 'double'}:
        return f'c.Number(double({expr}))'
    if typ in PRIMITIVES:
        # Textual representation preserves all components and avoids JSON NaN.
        return f'c.Text(tostring({expr}))'
    if typ == 'UnnamedEnum' or '::E' in typ or typ.startswith('E'):
        return f'Json::Value(int({expr}))'
    return None


def generate(game, define, inventory):
    names = {x['name'] for x in inventory if x['nod']}
    lines = [f'#if DIAGNOSTICS && {define}', '// Generated by scripts/generate-diagnostics.py; do not edit.',
             'bool DiagnosticsReadType(DiagnosticsCapture@ c, CMwNod@ node, const string &in type, Json::Value &inout fields, uint depth)', '{']
    for item in inventory:
        if item['name'] in names:
            lines.append(f'    if (type == "{item["name"]}") {{ DiagnosticsRead_{item["name"]}(c, cast<{item["name"]}>(node), fields, depth); return true; }}')
    lines += ['    return false;', '}']
    counts = {'types': len(names), 'members': 0, 'readable': 0, 'excluded': 0, 'unsupported': 0}
    for item in inventory:
        name = item['name']
        if name not in names:
            continue
        lines += [f'void DiagnosticsRead_{name}(DiagnosticsCapture@ c, {name}@ node, Json::Value &inout fields, uint depth)', '{', '    if (node is null) return;']
        for member in item['members']:
            field, typ = member['name'], member['type']
            counts['members'] += 1
            key = f'{name}.{field}'
            expr = f'node.{field}'
            arr = re.fullmatch(r'Mw(?:FastBuffer|FastArray|SArray|StridedArray|Array)<(.+)>', typ)
            value = expression(arr[1] if arr else typ, f'{expr}[i]' if arr else expr, names)
            if key in WRITE_ONLY_MEMBERS or member.get('readable') is False:
                code = f'c.Skipped("{key}", "unsupported", "getter unavailable; compile-time read excluded")'
                counts['unsupported'] += 1
            elif PRIVATE.search(field):
                code = f'c.Skipped("{key}", "excluded", "sensitive-name policy")'
                counts['excluded'] += 1
            elif value is None:
                code = f'c.Skipped("{key}", "unsupported", "{typ}")'
                counts['unsupported'] += 1
            else:
                counts['readable'] += 1
                if arr:
                    code = f'Json::Value values = Json::Array(); uint length = node.{field}.Length; for (uint i = 0; i < length && i < c.maxArray; i++) values.Add({value}); c.ArrayField(fields, "{key}", values, length)'
                else:
                    code = f'c.Field(fields, "{key}", {value})'
            lines += ['    if (c.Checkpoint()) return;', f'    c.member = "{key}";', f'    try {{ {code}; }} catch {{ c.Skipped("{key}", "failed", "getter exception"); }}']
        lines += ['}']
    digest = hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()
    lines += [f'string DiagnosticsInventoryHash() {{ return "{digest}"; }}', '#endif', '']
    (OUT / f'{game}.as').write_text('\n'.join(lines))
    print(game, counts, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refresh', action='store_true')
    parser.add_argument('--game', choices=['all', 'turbo', 'next'], default='all')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for game, (define, root) in GAMES.items():
        if args.game not in ('all', game):
            continue
        cache = OUT / f'{game}-api.json'
        if args.refresh:
            cache.write_text(json.dumps(refresh(game, root), indent=2) + '\n')
        generate(game, define, json.loads(cache.read_text()))
