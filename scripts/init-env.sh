#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -e .env ]; then echo '.env já existe; preservado.'; exit 0; fi
umask 077
python3 - <<'PY'
import pathlib, secrets
content = pathlib.Path('.env.example').read_text()
for key in ('POSTGRES_PASSWORD', 'REDIS_PASSWORD', 'RABBITMQ_PASSWORD', 'MEDIA_S3_ACCESS_KEY', 'MEDIA_S3_SECRET_KEY'):
    content = content.replace(key + '=\n', key + '=' + secrets.token_hex(24) + '\n')
with pathlib.Path('.env').open('x') as output:
    output.write(content)
PY
echo '.env criado com segredos aleatórios locais.'
