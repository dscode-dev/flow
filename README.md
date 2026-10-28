# Flow V1 — PR-00

Fundação Go e Flutter. O workspace e o [repositório informado](https://github.com/dscode-dev/flow) estavam vazios; a base mobile é nova. Preservação de Rolezin/Mapbox e marca final dependem da entrega do legado. Ver [auditoria](docs/architecture/initial-audit.md) e [relatório PR-00](docs/architecture/pr-00-completion-report.md).

## Requisitos

Go 1.27.3, Flutter 3.47.8 (Dart 3.13.7), Docker Engine/Compose v2, Python 3 e curl. SDKs Android/iOS e assinatura para executar em aparelhos. Não é necessário instalar PostgreSQL, Redis, RabbitMQ, goose ou sqlc globalmente.

## Ambiente local

```sh
make env
make up
make ps
make smoke
make down
```

`make env` gera `.env` privado com segredos aleatórios; não sobrescreve existente. Ajuste portas e `HOST_BIND` nesse arquivo. Bind padrão somente loopback; API 18080, PostgreSQL 15432, Redis 16379, AMQP 15672, gestão RabbitMQ 15673. Contratos não contêm hosts fixos. Não usar segredos com caracteres reservados de URL sem percent-encoding na composição de DSNs; os gerados em hexadecimal já são seguros. Não versionar `.env`, dados de volume, certificados ou tokens Mapbox.

`make up` compila API/migrate/probe, aguarda saúde das dependências, executa goose e inicia API sem root, sem capabilities e com filesystem read-only. Migrações são explícitas, fora do startup da API. `make down` para/remove apenas contêineres/rede deste projeto, preservando volumes. Não use `down -v` se precisar manter dados. Portas internas e loopback no probe de contêiner são detalhes de infraestrutura local, não suposições dos clientes.

```sh
curl -i http://127.0.0.1:18080/healthz
curl -i http://127.0.0.1:18080/readyz
make migrate-down
make migrate-up
```

Probes: liveness 200 sem dependências; readiness 200 quando PostgreSQL/Redis/RabbitMQ estão disponíveis, 503 durante falha/encerramento. Não existe endpoint de autenticação ou CRUD. `make smoke` é **somente para ambiente de teste vazio**: faz down/up da migração técnica e interrompe Redis temporariamente, verificando recuperação. Nunca executá-lo em produção ou quando houver eventos que devam ser preservados. Rollback não remove PostGIS.

Observabilidade opcional: configure `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318` em `.env` e execute:

```sh
docker compose --env-file .env -f infra/compose/compose.yaml --profile observability up -d --build --wait
docker compose --env-file .env -f infra/compose/compose.yaml logs --tail=30 otel-collector
docker compose --env-file .env -f infra/compose/compose.yaml --profile observability down
```

Collector recebe somente na rede Docker, sem porta pública. Traces são amostrados; logs JSON da API têm IDs de correlação sem URL, corpo ou segredo. O exportador debug não é armazenamento de produção.

## Mobile

```sh
cd apps/mobile
flutter pub get --enforce-lockfile
flutter run --dart-define=FLOW_ENV=development --dart-define=API_BASE_URL=https://SEU_HOST/
```

Use URL HTTPS alcançável pelo aparelho e com barra final. `SEU_HOST` é substituído pelo endpoint do ambiente; não há default embutido. Dart-define é configuração pública, nunca secret injection. HTTP de desenvolvimento pode exigir configuração nativa restrita específica; não desabilite TLS globalmente no release. IDs `com.example`, ícones padrão e assinatura são provisórios e impedem publicação até serem substituídos por valores aprovados. Roteiro físico e associação de links em [workflow](docs/architecture/development-workflow.md).

## Verificação

```sh
make backend-check
make contracts
make sqlc
make mobile-check
```

`FLUTTER=/caminho/do/sdk/bin/flutter make mobile-check` seleciona uma instalação sem alterar SDK compartilhado. Testes de widget não provam execução de plugins em aparelhos. GitHub Actions verifica código e smoke; workflow só roda após o usuário autorizar commit/push, que não foram feitos nesta tarefa.

Arquitetura em [visão geral](docs/architecture/system-overview.md), [módulos](docs/architecture/module-boundaries.md), [contratos](contracts/README.md), [ADRs](docs/decisions/0001-modular-go.md), [P2P](docs/architecture/p2p-v1.md), [governança](docs/privacy/data-governance.md) e [capacidades administrativas](docs/admin-capabilities.md). PRs futuros devem atualizar o registro administrativo conforme o impacto da feature.
