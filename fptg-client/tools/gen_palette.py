"""Палитры цветов имени и профиля — из живого tdlib_raw.log в SCSS и JS.

Классы, а не style: правило проекта (CLAUDE.md). Палитра конечна, TDLib
присылает её целиком в updateAccentColors / updateProfileAccentColors
(td_api.tl: accentColor, profileAccentColor). Берётся ПОСЛЕДНЕЕ
обновление каждого вида. Встроенные цвета имени 0..6 в update не
приходят — их один цвет берётся из $accent-light/$accent-dark.

Запуск: C:/Python314/python.exe tools/gen_palette.py
Пишет web/assets/scss/base/_palette.scss и web/assets/js/util/palette.js.
SCSS компилирует пользователь сам.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = os.path.join(ROOT, 'tdlib_raw.log')
SCSS = os.path.join(ROOT, 'web', 'assets', 'scss', 'base', '_palette.scss')
JS = os.path.join(ROOT, 'web', 'assets', 'js', 'util', 'palette.js')
BUILT_IN = range(7)


def hexc(v):
    return '#%06x' % (int(v) & 0xFFFFFF)


def latest(kind):
    found = None
    with open(LOG, encoding='utf-8', errors='replace') as f:
        for line in f:
            if '"@type":"%s"' % kind not in line:
                continue
            try:
                j = json.loads(line[16:])
            except ValueError:
                continue
            if j.get('@type') == kind:
                found = j['colors']
    if found is None:
        raise SystemExit('no %s in %s' % (kind, LOG))
    return found


def three(colors):
    c = [hexc(x) for x in colors] or ['transparent']
    while len(c) < 3:
        c.append(c[-1] if len(c) < 2 else 'transparent')
    return c


names = latest('updateAccentColors')
profiles = latest('updateProfileAccentColors')

# Порядок как у нативного окна: встроенные, потом двухцветные, потом
# трёхцветные — внутри группы по id.
name_ids = list(BUILT_IN) \
    + sorted(c['id'] for c in names if len(c['light_theme_colors']) == 2) \
    + sorted(c['id'] for c in names if len(c['light_theme_colors']) >= 3)
profile_ids = sorted(c['id'] for c in profiles
                     if len(c['light_theme_colors']['palette_colors']) == 1) \
    + sorted(c['id'] for c in profiles
             if len(c['light_theme_colors']['palette_colors']) >= 2)

light, dark = [], []
for i in BUILT_IN:
    for out, m in ((light, '$accent-light'), (dark, '$accent-dark')):
        out.append('.swatch-a%d { --swatch-1: #{map.get(%s, "a%d")}; '
                   '--swatch-2: #{map.get(%s, "a%d")}; --swatch-3: transparent; }'
                   % (i, m, i, m, i))
for c in names:
    for out, key in ((light, 'light_theme_colors'), (dark, 'dark_theme_colors')):
        a, b, d = three(c[key])
        if len(c[key]) < 3:
            d = 'transparent'
        out.append('.swatch-a%d { --swatch-1: %s; --swatch-2: %s; --swatch-3: %s; }'
                   % (c['id'], a, b, d))
for c in profiles:
    for out, key in ((light, 'light_theme_colors'), (dark, 'dark_theme_colors')):
        p = c[key]['palette_colors']
        bg = c[key]['background_colors'] or p
        a = hexc(p[0])
        b = hexc(p[1]) if len(p) > 1 else a
        g1 = hexc(bg[0])
        g2 = hexc(bg[1]) if len(bg) > 1 else g1
        out.append('.swatch-p%d { --swatch-1: %s; --swatch-2: %s; --swatch-3: transparent; '
                   '--profile-bg-1: %s; --profile-bg-2: %s; }' % (c['id'], a, b, g1, g2))

scss = ['// СГЕНЕРИРОВАНО tools/gen_palette.py из tdlib_raw.log — руками не править.',
        '// Кружки выбора цвета имени (.swatch-aN) и профиля (.swatch-pN):',
        '// --swatch-1/2 — половинки круга, --swatch-3 — точка в центре',
        '// (третий цвет), --profile-bg-* — фон шапки профиля в предпросмотре.',
        '@use "sass:map";',
        '@use "../abstracts" as *;',
        '',
        '@mixin swatches-light {']
scss += ['  ' + x for x in light]
scss += ['}', '', '@mixin swatches-dark {']
scss += ['  ' + x for x in dark]
scss += ['}', '',
         '@include swatches-light;',
         '@media (prefers-color-scheme: dark) {',
         '  :root:not([data-theme="light"]) { @include swatches-dark; }',
         '}',
         ':root[data-theme="dark"] { @include swatches-dark; }',
         ':root[data-theme="light"] { @include swatches-light; }',
         '']
with open(SCSS, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(scss))

js = ['// СГЕНЕРИРОВАНО tools/gen_palette.py из tdlib_raw.log — руками не править.',
      '// Порядок кружков в выборе цвета; сами цвета — классы .swatch-aN /',
      '// .swatch-pN в base/_palette.scss.',
      '',
      'export const NAME_COLORS = %s;' % json.dumps(name_ids),
      'export const PROFILE_COLORS = %s;' % json.dumps(profile_ids),
      '']
with open(JS, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(js))

print('names', len(name_ids), 'profiles', len(profile_ids))
