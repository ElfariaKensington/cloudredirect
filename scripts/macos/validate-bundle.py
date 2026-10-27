#!/usr/bin/env python3
"""Check signing, executable dependencies and absence of the retired GUI stack."""
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
for path in app.rglob('*'):
    if not path.is_file():
        continue
    if 'qt' in path.name.lower() or path.suffix == '.qml' or path.name == 'CloudRedirectBackend':
        raise SystemExit(f'Unexpected legacy interface file: {path.relative_to(app)}')
    kind = subprocess.run(['file', '-b', str(path)], text=True, capture_output=True, check=True).stdout
    if 'Mach-O' not in kind:
        continue
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
    links = subprocess.run(['otool', '-L', str(path)], text=True, capture_output=True, check=True).stdout
    if any(value in links for value in ('QtCore', 'QtGui', 'QtQuick', 'QtNetwork', '/opt/homebrew/', '/usr/local/')):
        raise SystemExit(f'Non-system dynamic dependency: {path.relative_to(app)}\n{links}')
print('Native bundle signatures and dependencies verified.')
