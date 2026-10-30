#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
compose() { docker compose --env-file .env -f infra/compose/compose.yaml "$@"; }
compose exec -T postgres sh -c 'if [ "$(psql -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_database WHERE datname = '\''flow_experiences_test'\''")" != 1 ]; then createdb -U "$POSTGRES_USER" flow_experiences_test; fi'
python3 - <<'PY'
import os,pathlib,urllib.parse
values=dict(line.split('=',1) for line in pathlib.Path('.env').read_text().splitlines() if line.strip() and not line.lstrip().startswith('#') and '=' in line)
def value(k,d=''): return os.environ.get(k,values.get(k,d)).strip('"\x27')
q=urllib.parse.quote
env=os.environ.copy()
env['FLOW_EXPERIENCES_TEST_DATABASE_URL']='postgres://'+q(value('POSTGRES_USER','flow'),safe='')+':'+q(value('POSTGRES_PASSWORD'),safe='')+'@127.0.0.1:'+value('POSTGRES_PORT','15432')+'/flow_experiences_test?sslmode=disable'
env['MEDIA_S3_ENDPOINT']='http://127.0.0.1:'+value('S3_PORT','18333')
env['MEDIA_S3_PUBLIC_ENDPOINT']=env['MEDIA_S3_ENDPOINT']
for k in ('MEDIA_S3_REGION','MEDIA_S3_BUCKET','MEDIA_S3_ACCESS_KEY','MEDIA_S3_SECRET_KEY'): env[k]=value(k)
os.chdir('backend')
os.execvpe('go',['go','test','-tags=integration','./internal/experiences/integration','-count=1','-v'],env)
PY
