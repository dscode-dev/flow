#!/bin/sh
# Somente ambiente local isolado: faz rollback de uma migração e interrompe Redis.
set -eu
cd "$(dirname "$0")/.."
compose() { docker compose --env-file .env -f infra/compose/compose.yaml "$@"; }
if [ ! -f .env ]; then echo 'Execute make env e make up primeiro.'; exit 1; fi
# Compose mantém a precedência das variáveis exportadas sobre .env. Não executar
# .env como shell nem sobrescrever COMPOSE_PROJECT_NAME de uma stack de teste.
api_port="${API_PORT:-}"
if [ -z "$api_port" ]; then
  api_port=$(python3 - <<'PY'
from pathlib import Path
values = dict(line.strip().split('=', 1) for line in Path('.env').read_text().splitlines()
              if line.strip() and not line.lstrip().startswith('#') and '=' in line)
print(values.get('API_PORT', '18080').strip('\"\x27'))
PY
)
fi
probe_url="http://${SMOKE_HOST:-127.0.0.1}:$api_port"
check() {
  path="$1"; wanted="$2"
  got=$(curl --silent --show-error --max-time 6 -o /dev/null -w '%{http_code}' "$probe_url$path")
  if [ "$got" != "$wanted" ]; then echo "Falha $path: esperado $wanted, recebido $got"; exit 1; fi
}
restore() { compose start redis >/dev/null 2>&1 || true; }
trap restore EXIT HUP INT TERM
check /healthz 200
check /readyz 200
check /missing 404
compose run --rm migrate /app/migrate status
# O rollback afeta apenas as tabelas técnicas; executar antes de eventos reais.
compose run --rm migrate /app/migrate down
compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
DO $$ BEGIN
 IF to_regclass('integration.outbox') IS NOT NULL OR to_regclass('integration.inbox') IS NOT NULL THEN
  RAISE EXCEPTION 'rollback não removeu tabelas técnicas';
 END IF;
 IF NOT EXISTS (SELECT FROM pg_extension WHERE extname = 'postgis') THEN
  RAISE EXCEPTION 'rollback removeu extensão compartilhada';
 END IF;
END $$;
SQL
compose run --rm migrate /app/migrate up
compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
BEGIN;
INSERT INTO integration.outbox (event_id,event_type,schema_version,aggregate_id,occurred_at,payload)
VALUES ('00000000-0000-4000-8000-000000000001','foundation.verified',1,'00000000-0000-4000-8000-000000000002',now(),'{}');
INSERT INTO integration.inbox (consumer,event_id) VALUES ('smoke','00000000-0000-4000-8000-000000000001');
INSERT INTO integration.inbox (consumer,event_id) VALUES ('smoke','00000000-0000-4000-8000-000000000001') ON CONFLICT DO NOTHING;
DO $$ BEGIN
 IF (SELECT count(*) FROM integration.inbox WHERE consumer='smoke') <> 1 THEN RAISE EXCEPTION 'deduplicação falhou'; END IF;
END $$;
ROLLBACK;
DO $$ BEGIN
 IF EXISTS (SELECT FROM integration.outbox WHERE event_id='00000000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'rollback não foi atômico'; END IF;
END $$;
SQL
check /readyz 200
compose stop redis
check /healthz 200
check /readyz 503
compose start redis
attempt=0
until curl --silent --fail --max-time 6 "$probe_url/readyz" >/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 15 ]; then echo 'Readiness não recuperou'; exit 1; fi
  sleep 1
done
echo 'Smoke passou: probes, rollback/up, PostGIS preservado, transação, inbox e recuperação Redis.'
