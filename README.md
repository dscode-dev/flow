# Flow V1 — Identity, Experiences, Discovery e Participação

PR-06 entrega [Participação, convites, Minha Agenda e check-in](docs/features/participation.md): modalidades FREE/APPROVAL/INVITE, capacidade transacional PostgreSQL, convites individuais, gestão contextual e código temporário validado pelo organizador. PRIVATE exige convite, interesse não ocupa vaga e presença não comprova ingresso externo. [ADR0011](docs/decisions/0011-participation-capacity-checkin.md) e [relatório](docs/architecture/pr-06-completion-report.md).

PR-05 entrega [Explorar](docs/features/explore.md) e [Flows](docs/features/flows.md): busca PostgreSQL indexada, carrossel e viewer vertical, apresentação subordinada à Experience, imagens/vídeo≤15s e processamento assíncrono no worker Go/FFmpeg. UNLISTED exige consentimento público explícito; PRIVATE nunca aparece. Sem P2P, feed pessoal ou métricas fictícias. [ADR0010](docs/decisions/0010-explore-flows-exposure-media.md) e [relatório](docs/architecture/pr-05-completion-report.md).

Flow é uma implementação nova, por decisão de produto no [ADR 0005](docs/decisions/0005-fresh-flow.md), sem migração ou dependência do Rolezin. PR-00 entrega fundação Go/Flutter; PR-01.A entrega Identity por PHONE/GOOGLE/APPLE; PR-01.B implementa autenticação Flutter, onboarding e sessão segura, com configuração/homologação externas pendentes. Ver [Identity](docs/features/identity.md), [contratos mobile](docs/features/identity-mobile-integration.md), [configuração/roteiro físico](docs/features/mobile-authentication.md) e [relatório PR-01.A](docs/architecture/pr-01a-completion-report.md).

PR-03 entrega [Início / Home Discovery](docs/features/home-discovery.md): composição Go/PostGIS real, seis seções limitadas, região aproximada manual sem GPS, cards Flutter e detalhes existentes. Configuração HOME_SOON_HOURS/HOME_RADIUS_M/HOME_SECTION_LIMIT documentada; sem conteúdo fictício, recomendação social ou mapa simulado. `make experiences-mobile-contract` cobre agora também a Home no bridge Flutter/Go/PostGIS/S3. [Relatório do ciclo](docs/architecture/pr-03-completion-report.md).

PR-04 implementa [Radar](docs/features/radar.md): viewport PostGIS/antimeridiano, marcadores limitados, filtros e integração oficial Mapbox3.34.2. O proprietário informou que gerou token; a configuração é local e renderização real/homologação seguem pendentes de evidência. Sem token configurado, o app mostra configuração indisponível. Configuração pública local, privacidade e roteiro físico no guia. O bridge existente também testa o Radar contra a API real, sem confundir isso com runtime de tiles/clusters. [Relatório PR-04](docs/architecture/pr-04-completion-report.md).

## Requisitos

Go 1.27.3, Flutter 3.47.8 (Dart 3.13.7), Docker Engine/Compose v2, Python 3 e curl. SDKs Android/iOS e assinatura para executar em aparelhos. Não é necessário instalar PostgreSQL, Redis, RabbitMQ, goose ou sqlc globalmente.

Os testes de integração de mídia executados no host também exigem `ffmpeg` e `ffprobe` no PATH. A imagem Docker da API/worker já inclui essas ferramentas.

Flutter está fixado em `.flutter-version`. Use `./flutterw` na raiz (ou `../../flutterw` dentro de `apps/mobile`): o SDK oficial fica em `.toolchains/`, ignorado pelo Git, com instalação inicial via Git/rede. O diretório é persistente e independente do Flutter global/PATH; não usar instalações em `/private/tmp` nos comandos habituais. `make mobile-check` usa esse wrapper por padrão; `FLUTTER=...` continua permitindo outra instalação, como o SDK já preparado pela CI.

## Ambiente local

```sh
make env
make up
make ps
make smoke
make down
```

`make env` gera `.env` privado com segredos aleatórios; preserva valores existentes e adiciona chaves novas de módulo. Ajuste portas e `HOST_BIND` nesse arquivo. Bind padrão somente loopback; API18080, PostgreSQL15432, Redis16379, AMQP15672, gestão RabbitMQ15673, S3 privado18333. Contratos não contêm hosts fixos. Não usar segredos com caracteres reservados de URL sem percent-encoding na composição de DSNs; os gerados em hexadecimal já são seguros. Não versionar `.env`, dados de volume, certificados ou tokens Mapbox.

`make up` compila API/migrate/probe, aguarda saúde das dependências, executa goose e inicia API sem root, sem capabilities e com filesystem read-only. Migrações são explícitas, fora do startup da API. `make down` para/remove apenas contêineres/rede deste projeto, preservando volumes. Não use `down -v` se precisar manter dados. Portas internas e loopback no probe de contêiner são detalhes de infraestrutura local, não suposições dos clientes.

```sh
curl -i http://127.0.0.1:18080/healthz
curl -i http://127.0.0.1:18080/readyz
make migrate-down
make migrate-up
```

Probes: liveness200 sem dependências; readiness200 quando PostgreSQL/Redis/RabbitMQ estão disponíveis, 503 durante falha/encerramento. Endpoints reais no OpenAPI; nenhum CRUD Users/admin. `make smoke` é **somente para ambiente de teste vazio**: down/up das oito migrations (manutenção Participation, Participation, Flows, índice Radar, índice Home, Experiences/Media, Identity e fundação), com guardas para contas/experiências/mídia/integração existentes; interrompe e restaura Redis. Nunca executar em produção ou com dados a preservar. Rollback não remove PostGIS. S3 indisponível retorna503 nas operações de mídia, sem bloquear experiências sem capa.

Observabilidade opcional: configure `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318` em `.env` e execute:

```sh
docker compose --env-file .env -f infra/compose/compose.yaml --profile observability up -d --build --wait
docker compose --env-file .env -f infra/compose/compose.yaml logs --tail=30 otel-collector
docker compose --env-file .env -f infra/compose/compose.yaml --profile observability down
```

Collector recebe somente na rede Docker, sem porta pública. Traces são amostrados; logs JSON da API têm IDs de correlação sem URL, corpo ou segredo. O exportador debug não é armazenamento de produção.

## Mobile

Para o iPhone usar a API local deste Mac:

```sh
make mobile-local
cd apps/mobile
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

O comando detecta o IPv4 privado do Mac, inicia a stack e libera API e S3 privado para upload de capas nesse IP; banco, Redis e RabbitMQ continuam em loopback. Não altere `HOST_BIND` para expor dependências. Mac/iPhone precisam estar na mesma rede; permita Rede Local no iPhone quando solicitado e mantenha Docker/backend ligados. Se necessário, selecione a interface com `FLOW_MOBILE_BIND_IP=<IPv4 do Mac> make mobile-local`. Se mudar de rede/IP, execute novamente e recompile: dart-defines são incorporados no build. `.env.mobile.local` e `config/device.local.json` são ignorados pelo Git. Para encerrar, `make mobile-local-down` preserva os volumes.

Esse ambiente usa HTTP de desenvolvimento e Apple desativado para Personal Team. Twilio/Google/Apple continuam exigindo credenciais reais; não há login simulado. O bucket S3 permanece privado e o backend emite a autorização de upload com o endpoint alcançável, sem reescrever assinaturas no cliente. A permissão iOS de rede local é declarada sem liberar TLS globalmente.

Para outro backend configurado:

```sh
cd apps/mobile
../../flutterw pub get --enforce-lockfile
../../flutterw run --dart-define=FLOW_ENV=development --dart-define=API_BASE_URL=https://SEU_HOST/
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

## Identity — configuração e testes

Acesso temporário local por telefone/código pode ser habilitado explicitamente para um único número, sem envio de SMS e com sessão/onboarding reais. Desativado por padrão e recusado em produção. [Configuração, uso e desativação](docs/features/development-phone-login.md); número/código ficam apenas no `.env` privado do servidor.

`make env` também gera a chave HMAC local quando ausente/vazia; API falha se ela estiver inválida. Sem credenciais externas, provedores ficam indisponíveis (503), sem simular entrega ou login. Preencher TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN/TWILIO_VERIFY_SERVICE_SID, GOOGLE_CLIENT_IDS e APPLE_CLIENT_IDS somente com valores reais do proprietário. Consulte os [pré-requisitos](docs/features/identity.md) e o [ADR SMS](docs/decisions/0007-sms-provider.md). Não colocar credenciais de servidor em dart-define.

```sh
make up
make identity-test
make contracts
make sqlc
```

`identity-test` usa exclusivamente banco separado `flow_identity_test`, PostgreSQL real e HTTP real; para Redis da stack temporariamente e o restaura. Upstreams Twilio/Google/Apple são controlados somente em testes. O comando recria schemas no banco de teste, nunca no banco principal. Testes criptográficos usam par RSA de fixture, sem vínculo com provedores reais. Testes físicos e telas não fazem parte de PR-01.A.

Retenção operacional: com política revisada, agendar `/app/identity-retention` diariamente na mesma imagem, com DATABASE_URL injetada e papel autorizado. Não é um serviço adicional ou endpoint HTTP. Ele respeita a janela de refresh até expiração absoluta +30 dias e não apaga contas, identidades ou eventos pendentes.


## Fechamento Identity — PR-01.C

Revisão/correções de sessão e validação entre cliente/API estão em [relatório PR-01.C](docs/architecture/pr-01c-completion-report.md). [Configuração por ambiente e checklist externo](docs/features/authentication-release-readiness.md) distinguem estrutura, testes locais, simulador, aparelhos, provedores e CI. IDs finais, marca, URLs e credenciais ainda serão criados pelo proprietário; não há aceite integral de produção.

`make auth-readiness` retorna pendências de configuração sem expor segredos. `make identity-mobile-contract FLUTTER=/caminho/do/sdk/bin/flutter` valida Flutter/Dio contra Go HTTP/OpenAPI e PostgreSQL isolado com upstreams de fixture; não faz SMS/OAuth real. O smoke em `apps/mobile/integration_test/auth_native_test.dart` exige simulador limpo. Nenhuma associação de domínio ou identificador final é presumido.

## Experiences — PR-02.A

PR-02.B entrega o cliente Flutter de criação/gestão integrado: [telas, navegação e operação](docs/features/flutter-experiences.md). Para verificar contra Go/PostGIS/S3 reais, execute `make experiences-mobile-contract` com a stack ativa. Sessões sintéticas só existem no harness de teste isolado, sem bypass no app.

Backend físico com drafts, publicação, edições protegidas/ETag, cancelamento/arquivo, categorias, PUBLIC/UNLISTED/PRIVATE, PostGIS, idempotência e auditoria/outbox. [Arquitetura e operação](docs/features/experiences.md), [schema](docs/architecture/experiences-database.md), [contrato Flutter PR-02.B](docs/features/experiences-mobile-integration.md). Sem RSVP/pagamento/feed/admin ou telas Experiences neste PR.

`make up` inclui servidor S3 compatível real local (SeaweedFS4.51, bucket privado/volume próprio). `make experiences-test` valida HTTP/OpenAPI, pgx/PostGIS e uploads reais em **flow_experiences_test** e bucket exclusivo **flow-experiences-test**; recria apenas schemas de teste. `make experiences-maintenance` limpa órfãos/staging/idempotência/quotas e retenção técnica em batches. Produção precisa agendamento, lifecycle/backup/TLS/IAM e fornecedor aprovado; nada foi provisionado em nuvem.

Social PR-07: [funcionalidade, API e operação](docs/features/social.md), [ADR0012](docs/decisions/0012-social-publication-graph-media.md). Validação isolada: `make social-test` e `make social-mobile-contract`. Acesso pelo botão Social na Home, com autenticação existente. Nenhum deep link externo inventado.

Event Space (PR-08): [matriz, contratos, moderação e operação](docs/features/event-space.md), [ADR0013](docs/decisions/0013-event-space-context-authorization.md). Validação isolada: `make event-space-test` e `make event-space-mobile-contract`.

Chat contextual (PR-09): [contratos, privacidade e operação](docs/features/chat.md), [ADR0014](docs/decisions/0014-chat-persistence-realtime.md). Testes isolados: `make chat-test` e `make chat-mobile-contract`.
