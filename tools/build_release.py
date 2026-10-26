"""Building an fptg release for Windows x64: two archives in dist/.

    python tools\\build_release.py 1.0.0 [--no-build | --build-only]

--no-build — package the exe files already built (checking the packaging
itself, or packaging exe files signed after --build-only).
--build-only — build the three programs and stop (CI: they go to signing
first, then --no-build packs the signed ones).

Every build stamps the version into the three programs' version info: the
same FileVersion and ProductVersion and ProductName "fptg" (code signing
wants them identical across a release). The .lpi files are restored
afterwards.

1. A full rebuild of the three programs (lazbuild -B): fptg-server,
   fptg-server-gui and fptg-client (the Release mode). The server window and
   the client window must be closed — otherwise the exe cannot be overwritten.
2. dist/fptg-server-<version>-win64.zip — both servers, tdjson.dll and its
   libraries, the page (web/ next to the exe — for browsers), licenses.
3. dist/fptg-client-<version>-win64.zip — the window, WebView2Loader.dll,
   the page (web/), licenses.
4. dist/SHA256SUMS.txt — the checksums of both archives.

Telegram API keys: if ../fptg-server-premium/apikeys.inc exists (not in
git), the server is built with them; otherwise — without built-in keys, and
the server asks for its own. The script says which variant was built.

The page sources (*.scss, maps, .idea) do not go into the archives: only the
compiled assets/scss/style.css is needed.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, 'fptg-server')
CLIENT = os.path.join(ROOT, 'fptg-client')
DIST = os.path.join(ROOT, 'dist')
# lazbuild: $LAZBUILD, then PATH (CI), then the usual install folder.
LAZBUILD = (os.environ.get('LAZBUILD') or shutil.which('lazbuild')
            or r'C:\lazarus\lazbuild.exe')
PRODUCT_NAME = 'fptg'

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

Data (accounts, settings, TDLib database) lives in data\\ next to the
programs: unpack into a folder you can write to. Every copy of this folder
is a separate server - give each its own port.

Quick start:
  fptg-server.exe --set-user=alice        (asks for a password)
  fptg-server.exe                         (asks who may connect)

The server can add itself to Windows Firewall when it is to be reached
from other computers.
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


def version_numbers(version):
    m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?', version)
    if not m:
        fail(f'the version must look like 1.2.3 or 1.2.3.4, not {version}')
    return [int(x or 0) for x in m.groups()]


def write_bytes(path, data):
    tmp = path + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)


def stamp_version(lpi, version):
    """The release version into the project's VersionInfo; returns the
    original bytes to restore."""
    with open(lpi, 'rb') as f:
        raw = f.read()
    text = raw.decode('utf-8')
    nl = '\r\n' if '\r\n' in text else '\n'
    major, minor, rev, build_nr = version_numbers(version)
    name = os.path.splitext(os.path.basename(lpi))[0]
    block = nl.join([
        '<VersionInfo>',
        '      <UseVersionInfo Value="True"/>',
        f'      <MajorVersionNr Value="{major}"/>',
        f'      <MinorVersionNr Value="{minor}"/>',
        f'      <RevisionNr Value="{rev}"/>',
        f'      <BuildNr Value="{build_nr}"/>',
        f'      <StringTable CompanyName="xsid86" FileDescription="{name}"'
        f' InternalName="{name}" LegalCopyright="xsid86"'
        f' OriginalFilename="{name}.exe" ProductName="{PRODUCT_NAME}"'
        f' ProductVersion="{version}"/>',
        '    </VersionInfo>'])
    new, n = re.subn(r'<VersionInfo>.*?</VersionInfo>', lambda _: block, text, flags=re.S)
    if n != 1:
        fail(f'{os.path.basename(lpi)}: no VersionInfo block')
    write_bytes(lpi, new.encode('utf-8'))
    return raw


def build_all(version):
    projects = [(os.path.join(SERVER, 'fptg-server.lpi'), None),
                (os.path.join(SERVER, 'fptg-server-gui.lpi'), None),
                (os.path.join(CLIENT, 'fptg-client.lpi'), 'Release')]
    saved = {}
    try:
        for lpi, _ in projects:
            saved[lpi] = stamp_version(lpi, version)
        for lpi, mode in projects:
            build(lpi, mode)
    finally:
        for lpi, raw in saved.items():
            write_bytes(lpi, raw)


def copy_web(dst, version):
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
    # The version the page shows (the menu): this build's, not the
    # repository's last release.
    stamp = os.path.join(dst, 'assets', 'js', 'version.js')
    text = open(stamp, encoding='utf-8').read()
    stamped = re.sub(r"APP_VERSION = '[^']*'", f"APP_VERSION = '{version}'", text)
    if stamped == text and f"'{version}'" not in text:
        fail('assets/js/version.js has no APP_VERSION to stamp')
    write_text(stamp, stamped)


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
    build_only = '--build-only' in sys.argv
    if len(args) != 1 or (no_build and build_only):
        fail('usage: build_release.py <version> [--no-build | --build-only], e.g. 1.0.0')
    version = args[0]
    version_numbers(version)
    for f in SERVER_FILES[2:]:
        if not os.path.exists(os.path.join(SERVER, f)):
            fail(f'fptg-server/{f} is missing')

    keys = os.path.exists(os.path.join(ROOT, 'fptg-server-premium', 'apikeys.inc'))
    if not no_build:
        build_all(version)
    if build_only:
        print('Built. Telegram API keys built in:', 'YES' if keys else 'NO')
        return

    os.makedirs(DIST, exist_ok=True)
    stage = os.path.join(DIST, f'stage-{version}')
    if os.path.exists(stage):
        shutil.rmtree(stage)

    srv = os.path.join(stage, f'fptg-server-{version}')
    os.makedirs(srv)
    for f in SERVER_FILES:
        shutil.copy2(os.path.join(SERVER, f), srv)
    copy_web(os.path.join(srv, 'web'), version)
    copy_legal(srv)
    write_text(os.path.join(srv, 'README.txt'), README_SERVER.format(version=version))

    cli = os.path.join(stage, f'fptg-client-{version}')
    os.makedirs(cli)
    for f in CLIENT_FILES:
        shutil.copy2(os.path.join(CLIENT, f), cli)
    copy_web(os.path.join(cli, 'web'), version)
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
