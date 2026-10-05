"""Builds emoji.json, the list the web picker offers.

    python build_emoji.py [path to emoji-test.txt]

The source is Unicode's emoji-test.txt (groups, names, CLDR order):
every fully-qualified emoji of the nine picker groups.

It used to be crossed with emoji_atlas.dat, the set the native LCL
window could draw, so an emoji picked in the web never turned into a
blank box there. The native window and the atlas are gone (2026-10-05);
emoji.json as committed is still that intersection, and running this
again offers everything emoji-test.txt lists.

The input comes from unicode.org/Public/emoji/<version>/emoji-test.txt
and is not kept in the repository, only its result is. Run this again
when a newer Unicode version is worth picking up.
"""
import io, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TEST_TXT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'emoji-test.txt')

TONES = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
TONESET = set(TONES)


def parse_test(path):
    group = None
    version = '?'
    rows = []
    for line in io.open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('# group: '):
            group = line[9:].strip()
            continue
        if line.startswith('# Version: '):
            version = line[11:].strip()
            continue
        if not line or line.startswith('#'):
            continue
        codes, _, rest = line.partition(';')
        if rest.split('#')[0].strip() != 'fully-qualified':
            continue
        cps = tuple(int(c, 16) for c in codes.split())
        tail = rest.split('#', 1)[1].strip().split(' ', 2)
        name = tail[2] if len(tail) > 2 else tail[-1]
        rows.append((group, cps, name))
    return version, rows


text = lambda cps: ''.join(chr(c) for c in cps)
base_of = lambda cps: tuple(c for c in cps if c not in TONESET)


# A group's strip button is an emoji, not an icon: the sheet in
# assets/img is for UI glyphs and says so at the top.
ICON = {
    'Smileys & Emotion': '\U0001F642',
    'People & Body': '\U0001F44B',
    'Animals & Nature': '\U0001F436',
    'Food & Drink': '\U0001F354',
    'Travel & Places': '\U0001F697',
    'Activities': '⚽',
    'Objects': '\U0001F4A1',
    'Symbols': '❤️',
    'Flags': '\U0001F3C1',
}
SLUG = {
    'Smileys & Emotion': 'smileys',
    'People & Body': 'people',
    'Animals & Nature': 'nature',
    'Food & Drink': 'food',
    'Travel & Places': 'travel',
    'Activities': 'activities',
    'Objects': 'objects',
    'Symbols': 'symbols',
    'Flags': 'flags',
}

version, rows = parse_test(TEST_TXT)

# Skin tones fold into the emoji they belong to: one cell in the grid
# with five alternatives behind it, the way every client shows them.
tones = {}
for group, cps, name in rows:
    if not (TONESET & set(cps)):
        continue
    tones.setdefault(base_of(cps), {})[sorted(TONESET & set(cps))[0]] = text(cps)

groups, index = [], {}
for group, cps, name in rows:
    if group not in SLUG or (TONESET & set(cps)):
        continue
    if group not in index:
        index[group] = {'id': SLUG[group], 'name': group,
                        'icon': ICON[group], 'items': []}
        groups.append(index[group])
    item = {'e': text(cps), 'n': name}
    variants = tones.get(cps)
    if variants and len(variants) == 5:
        item['t'] = [variants[t] for t in TONES]
    index[group]['items'].append(item)

out = os.path.join(HERE, 'emoji.json')
with io.open(out, 'w', encoding='utf-8', newline='\n') as f:
    json.dump({'version': version, 'groups': groups}, f,
              ensure_ascii=False, separators=(',', ':'))
    f.write('\n')

total = sum(len(g['items']) for g in groups)
toned = sum(1 for g in groups for i in g['items'] if 't' in i)
print('emoji.json: %d emoji in %d groups, %d of them with skin tones'
      % (total, len(groups), toned))
print('bytes: %d' % os.path.getsize(out))
for g in groups:
    print('  %-14s %4d' % (g['id'], len(g['items'])))
