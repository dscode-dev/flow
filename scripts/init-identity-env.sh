#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
umask 077
python3 - <<'PY'
import pathlib,secrets,re
p=pathlib.Path('.env')
if not p.exists(): raise SystemExit('Execute scripts/init-env.sh primeiro')
content=p.read_text()
current=next((line.split('=',1)[1].strip() for line in content.splitlines() if line.startswith('IDENTITY_HMAC_KEY=')),None)
if not current:
    entry='IDENTITY_HMAC_KEY='+secrets.token_hex(32)
    if current is None:
        with p.open('a') as f: f.write('\n'+entry+'\n')
    else:
        p.write_text(re.sub(r'^IDENTITY_HMAC_KEY=.*$',entry,content,flags=re.MULTILINE))
    print('Chave HMAC Identity local adicionada; nenhum provedor externo configurado.')
else: print('Configuração Identity existente preservada.')
PY
