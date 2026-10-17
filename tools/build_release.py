"""Сборка релиза fptg для Windows x64: два архива в dist/.

    python tools\\build_release.py 1.0.0 [--no-build]

--no-build — упаковать уже собранные exe (проверка самой упаковки).

1. Полная пересборка трёх программ (lazbuild -B): fptg-server,
   fptg-server-gui и fptg-client (режим Release). Окно сервера и окно
   клиента должны быть закрыты — иначе exe не перезаписать.
2. dist/fptg-server-<версия>-win64.zip — оба сервера, tdjson.dll и её
   библиотеки, страница (web/ рядом с exe — для браузеров), лицензии.
3. dist/fptg-client-<версия>-win64.zip — окно, WebView2Loader.dll,
   страница (web/), лицензии.
4. dist/SHA256SUMS.txt — суммы обоих архивов.

Ключи Telegram API: если есть ../fptg-server-premium/apikeys.inc (не в
git), сервер собирается с ними; иначе — без вшитых ключей, и сервер
попросит свои. Скрипт пишет, какой вариант собран.

Исходники страницы (*.scss, карты, .idea) в архивы не попадают: нужен
только скомпилированный assets/scss/style.css.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, 'fptg-server')
CLIENT = os.path.join(ROOT, 'fptg-client')
DIST = os.path.join(ROOT, 'dist')
LAZBUILD = r'C:\lazarus\lazbuild.exe'

SERVER_FILES = ['fptg-server.exe', 'fptg-server-gui.exe', 'tdjson.dll',
                'libssl-3-x64.dll', 'libcrypto-3-x64.dll', 'z.dll']
CLIENT_FILES = ['fptg-client.exe', 'WebView2Loader.dll', 'WebView2Loader.LICENSE.txt']
WEB_SKIP_DIRS = {'.idea'}
WEB_SKIP_EXT = {'.scss', '.map'}

README_SERVER = """fptg server {version}
=================

fptg-server.exe       console server (for a VPS); parameters are on the website
fptg-server-gui.exe   the same server with a small window and a tray icon
web\\                  the interface the server shows to browsers

Data (accounts, settings, TDLib database) lives in
%LOCALAPPDATA%\\fptg\\server\\, not next to the programs.

Quick start:
  fptg-server.exe --set-user=alice        (asks for a password)
  fptg-server.exe --server-port=443 --bind=0.0.0.0

Allow the port in Windows Firewall to reach the server from outside.
Requirements: 64-bit Windows 10 or 11 / Windows Server 2016 or newer.

License: GNU GPL v3 or later (LICENSE.txt, LICENSE-EXCEPTION.md).
Source code: https://github.com/xsid86/fptg
Third-party components: THIRD-PARTY-NOTICES.md, full texts in licenses\\.
fptg uses the Telegram API and is not affiliated with or endorsed by Telegram.
"""

README_CLIENT = """fptg client {version}
=================

Start fptg-client.exe, enter your server's address and port, check the
certificate fingerprint against the one the server shows, then sign in.

Requirements: 64-bit Windows 10 or 11 with the Microsoft Edge WebView2
Runtime. Windows 11 has it built in; on Windows 10 the client offers to
download it, or get it from
https://developer.microsoft.com/microsoft-edge/webview2/

License: GNU GPL v3 or later (LICENSE.txt, LICENSE-EXCEPTION.md).
Source code: https://github.com/xsid86/fptg
Third-party components: THIRD-PARTY-NOTICES.md, full texts in licenses\\.
fptg uses the Telegram API and is not affiliated with or endorsed by Telegram.
"""


def fail(msg):
    print('ERROR:', msg)
    sys.exit(1)


def build(lpi, mode=None):
    args = [LAZBUILD, '-B', lpi]
    if mode:
        args.append(f'--build-mode={mode}')
    print('building', os.path.relpath(lpi, ROOT), mode or '')
    r = subprocess.run(args, capture_output=True, text=True, encoding='cp866', errors='replace')
    out = r.stdout + r.stderr
    errors = [l for l in out.splitlines() if ' Error:' in l or 'Fatal:' in l]
    if r.returncode != 0 or errors:
        print('\n'.join(errors[-15:]))
        fail(f'{os.path.basename(lpi)} did not build (is the program still running?)')


def copy_web(dst):
    src = os.path.join(CLIENT, 'web')
    for base, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in WEB_SKIP_DIRS]
        rel = os.path.relpath(base, src)
        for f in files:
            if os.path.splitext(f)[1] in WEB_SKIP_EXT:
                continue
            os.makedirs(os.path.join(dst, rel), exist_ok=True)
            shutil.copy2(os.path.join(base, f), os.path.join(dst, rel, f))
    if not os.path.exists(os.path.join(dst, 'assets', 'scss', 'style.css')):
        fail('web/assets/scss/style.css is missing: compile the SCSS first')


def copy_legal(dst):
    shutil.copy2(os.path.join(ROOT, 'LICENSE'), os.path.join(dst, 'LICENSE.txt'))
    shutil.copy2(os.path.join(ROOT, 'LICENSE-EXCEPTION.md'), dst)
    shutil.copy2(os.path.join(ROOT, 'THIRD-PARTY-NOTICES.md'), dst)
    shutil.copytree(os.path.join(ROOT, 'docs', 'licenses'), os.path.join(dst, 'licenses'))


def write_text(path, text):
    with open(path, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write(text)


def zip_dir(folder, archive):
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        top = os.path.dirname(folder)
        for base, _, files in os.walk(folder):
            for f in files:
                full = os.path.join(base, f)
                z.write(full, os.path.relpath(full, top))
    print('wrote', os.path.relpath(archive, ROOT))


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    no_build = '--no-build' in sys.argv
    if len(args) != 1:
        fail('usage: build_release.py <version> [--no-build], e.g. 1.0.0')
    version = args[0]
    for f in SERVER_FILES[2:]:
        if not os.path.exists(os.path.join(SERVER, f)):
            fail(f'fptg-server/{f} is missing')

    keys = os.path.exists(os.path.join(ROOT, 'fptg-server-premium', 'apikeys.inc'))
    if not no_build:
        build(os.path.join(SERVER, 'fptg-server.lpi'))
        build(os.path.join(SERVER, 'fptg-server-gui.lpi'))
        build(os.path.join(CLIENT, 'fptg-client.lpi'), 'Release')

    os.makedirs(DIST, exist_ok=True)
    stage = os.path.join(DIST, f'stage-{version}')
    if os.path.exists(stage):
        shutil.rmtree(stage)

    srv = os.path.join(stage, f'fptg-server-{version}')
    os.makedirs(srv)
    for f in SERVER_FILES:
        shutil.copy2(os.path.join(SERVER, f), srv)
    copy_web(os.path.join(srv, 'web'))
    copy_legal(srv)
    write_text(os.path.join(srv, 'README.txt'), README_SERVER.format(version=version))

    cli = os.path.join(stage, f'fptg-client-{version}')
    os.makedirs(cli)
    for f in CLIENT_FILES:
        shutil.copy2(os.path.join(CLIENT, f), cli)
    copy_web(os.path.join(cli, 'web'))
    copy_legal(cli)
    write_text(os.path.join(cli, 'README.txt'), README_CLIENT.format(version=version))

    archives = [os.path.join(DIST, f'fptg-server-{version}-win64.zip'),
                os.path.join(DIST, f'fptg-client-{version}-win64.zip')]
    zip_dir(srv, archives[0])
    zip_dir(cli, archives[1])
    write_text(os.path.join(DIST, 'SHA256SUMS.txt'),
               ''.join(f'{sha256(a)}  {os.path.basename(a)}\n' for a in archives))
    shutil.rmtree(stage)

    print()
    print('Telegram API keys built in:', 'YES (fptg-server-premium/apikeys.inc)' if keys
          else 'NO - the server will ask for api_id and api_hash')
    print('Done:', os.path.relpath(DIST, ROOT))


if __name__ == '__main__':
    main()
