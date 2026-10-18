"""The Lazarus packages fptg needs, for a CI machine (GitHub Actions).

    python tools/ci_packages.py <folder>

Downloads them from the Online Package Manager repository
(packages.lazarus-ide.org), unpacks them into <folder> and registers only
the .lpk files the projects use (lazbuild --add-package-link). The OPM
archives hold more packages (Android, fpGUI and other variants); registering
those breaks on a plain Lazarus, so they are left alone.

On a developer machine the same packages come from the IDE:
Package -> Online Package Manager.
"""
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

OPM = 'https://packages.lazarus-ide.org/'
# archive -> the .lpk files inside it, in dependency order
PACKAGES = [
    ('Synapse40.1.zip', ['synapse40.1/laz_synapse.lpk']),
    ('QRCodeGenLib.zip', ['QRCodeGenLib/QRCodeGenLib/src/Packages/FPC/QRCodeGenLib4PascalPackage.lpk']),
    ('BGRABitmap.zip', ['BGRABitmap/bgrabitmap/bgrabitmappack.lpk']),
    ('BGRAControls.zip', ['BGRAControls/bgracontrols.lpk']),
]


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: ci_packages.py <folder>')
    root = os.path.abspath(sys.argv[1])
    os.makedirs(root, exist_ok=True)
    lazbuild = os.environ.get('LAZBUILD') or shutil.which('lazbuild')
    if not lazbuild:
        sys.exit('lazbuild is not on PATH')
    for archive, lpks in PACKAGES:
        target = os.path.join(root, archive)
        print('downloading', archive, flush=True)
        urllib.request.urlretrieve(OPM + archive, target)
        with zipfile.ZipFile(target) as z:
            z.extractall(root)
        for lpk in lpks:
            path = os.path.join(root, lpk)
            if not os.path.exists(path):
                sys.exit(f'{lpk} is not in {archive}')
            print('registering', lpk, flush=True)
            r = subprocess.run([lazbuild, '--add-package-link', path])
            if r.returncode != 0:
                sys.exit(f'lazbuild --add-package-link {lpk} failed ({r.returncode})')


if __name__ == '__main__':
    main()
