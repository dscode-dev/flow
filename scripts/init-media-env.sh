#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -f .env ]; then echo 'Execute make env primeiro.'; exit 1; fi
python3 - <<'PY'
import os,pathlib,secrets
path=pathlib.Path('.env')
content=path.read_text()
keys={line.split('=',1)[0] for line in content.splitlines() if '=' in line and not line.lstrip().startswith('#')}
add=[]
for line in pathlib.Path('.env.example').read_text().splitlines():
    if '=' not in line or line.lstrip().startswith('#'): continue
    key,value=line.split('=',1)
    if not (key.startswith(('EXPERIENCES_','MEDIA_S3_')) or key=='S3_PORT'): continue
    if key in keys: continue
    if key=='MEDIA_S3_ACCESS_KEY': value=secrets.token_hex(10)
    if key=='MEDIA_S3_SECRET_KEY': value=secrets.token_hex(24)
    add.append(key+'='+value)
if add:
    with path.open('a') as f: f.write('\n'+'\n'.join(add)+'\n')
os.chmod(path,0o600)
print('Configuração local de mídia conferida; valores existentes preservados.')
PY
