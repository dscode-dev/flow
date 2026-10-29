#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
compose() { docker compose --env-file .env -f infra/compose/compose.yaml "$@"; }
compose exec -T postgres sh -c 'if [ "$(psql -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_database WHERE datname = '\''flow_identity_test'\''")" != 1 ]; then createdb -U "$POSTGRES_USER" flow_identity_test; fi'
# Todas as integrações devem continuar autoritativas e limitadas com Redis parado.
restore() { compose start redis >/dev/null 2>&1 || true; }
trap restore EXIT HUP INT TERM
compose stop redis
python3 - <<'PY'
import os,pathlib,urllib.parse
values=dict(line.split('=',1) for line in pathlib.Path('.env').read_text().splitlines() if line.strip() and not line.lstrip().startswith('#') and '=' in line)
def value(k,d=''): return os.environ.get(k,values.get(k,d)).strip('"\x27')
q=urllib.parse.quote
env=os.environ.copy()
env['FLOW_IDENTITY_TEST_DATABASE_URL']='postgres://'+q(value('POSTGRES_USER','flow'),safe='')+':'+q(value('POSTGRES_PASSWORD'),safe='')+'@127.0.0.1:'+value('POSTGRES_PORT','15432')+'/flow_identity_test?sslmode=disable'
env['FLOW_IDENTITY_TEST_REDIS_URL']='redis://:'+q(value('REDIS_PASSWORD'),safe='')+'@127.0.0.1:'+value('REDIS_PORT','16379')+'/0'
os.chdir('backend')
os.execvpe('go',['go','test','-tags=integration','./internal/identity/integration','-count=1','-v'],env)
PY
