#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || exit 1
uv python install 3.12
HOST_PYTHON="$(uv python find 3.12)"
mkdir -p runtime toolbox .build
# Download the target runtime without executing ARM code on the Intel builder.
"$HOST_PYTHON" - <<'PY'
import json,urllib.request,tarfile,pathlib
r=json.load(urllib.request.urlopen('https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest'))
a=next(a for a in r['assets'] if a['name'].startswith('cpython-3.12.') and 'aarch64-apple-darwin-install_only.tar.gz' in a['name'])
archive=pathlib.Path('.build/python-arm64.tar.gz')
urllib.request.urlretrieve(a['browser_download_url'],archive)
with tarfile.open(archive) as t:t.extractall('runtime',filter='data')
print('ARM Python:',a['name'])
PY
# uv resolves markers and wheels for Apple Silicon, even on an Intel host.
uv pip install --python "$HOST_PYTHON" --python-version 3.12 --python-platform aarch64-apple-darwin --target "$PWD/runtime/python/lib/python3.12/site-packages" "$PWD/vendor/AstrBot-4.29.3"
curl --fail --location --retry 3 --output toolbox/toolbox https://storage.googleapis.com/mcp-toolbox-for-databases/v1.15.0/darwin/arm64/toolbox
chmod +x toolbox/toolbox
# Fail rather than distribute Intel-only native dependencies in an ARM app.
"$HOST_PYTHON" - <<'PY'
from pathlib import Path
import subprocess
files=[p for p in Path('runtime').rglob('*') if p.is_file() and not p.is_symlink()]+[Path('toolbox/toolbox')]
count=0
for p in files:
 with p.open('rb') as f:magic=f.read(4)
 if magic not in {bytes.fromhex(x) for x in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}:continue
 info=subprocess.check_output(['file','-b',str(p)],text=True)
 if 'Mach-O' in info:
  arches=subprocess.check_output(['lipo','-archs',str(p)],text=True)
  if 'arm64' not in arches.split():raise RuntimeError(f'Non-ARM native file: {p}: {arches}')
  count+=1
assert count>0
print(f'PASS: {count} native files include arm64')
PY
"$HOST_PYTHON" scripts/package_sources.py
pnpm install --frozen-lockfile --ignore-scripts
node node_modules/electron/install.js
CSC_IDENTITY_AUTO_DISCOVERY=false pnpm run dist:mac
shasum -a 256 release/*.dmg > release/SHA256.txt
printf '\nCross-built ARM installer; native Mac runtime testing is still required.\n'
