# Relatório de execução — PR-00

> Atualização PR-01.A: a decisão explícita de produto no [ADR 0005](../decisions/0005-fresh-flow.md) encerra a dependência de legado. Este documento preserva o registro histórico PR-00; não orienta procurar ou migrar Rolezin.
Data de referência: 27/10/2026, America/Recife. Trabalho local sem commit ou push.

## 1. Estado inicial

Workspace vazio, sem `.git`. Após o usuário fornecer `dscode-dev/flow`, clone confirmou remoto vazio, sem referências/commits; metadados Git foram associados ao workspace. Nenhum código Rolezin, tela, widget, Mapbox ou ativo de marca estava disponível. Auditoria funcional e preservação do legado não podem ser declaradas concluídas. Evidências e estratégia de integração futura estão em `initial-audit.md`.

## 2. Decisões e implementação

Monólito modular Go com API operacional e ferramenta de migração separada. Worker/P2P apenas documentados, sem executáveis ociosos. HTTP net/http + chi, configuração validada, timeouts/limites, logs JSON sanitizados com correlação, OTel opcional e graceful shutdown. Health independente de dependências; readiness verifica PostgreSQL/Redis/RabbitMQ e encerramento. Sem login, CRUD ou entidades especulativas.

PostgreSQL/PostGIS com pgx e consultas sqlc; goose com down/up, outbox/inbox técnicas e helper transacional. Não há relay ou consumidores funcionais. Mobile novo com bootstrap, ambientes, Dio, erros seguros, SecureStore, contrato AuthState, go_router, Material 3 claro/escuro, tokens e componentes de estado/card/sheet. Nenhum dado falso de negócio ou fluxo autenticado implementado.

Compose com secrets locais gerados, portas configuráveis, API sem root, FS read-only e collector opcional. GitHub Actions cobre Go, Flutter, contratos, drift sqlc e smoke. Contratos e limites de módulos, ADRs, LGPD, P2P e capacidades administrativas documentados. Administração não implementada.

## 3. Arquivos/módulos

- `apps/mobile`: projeto Android/iOS, `lib/core`, `lib/design`, app/bootstrap, testes, pubspec e lock, pin SDK.
- `backend`: cmd/api, migrate, probe, contractcheck, documentação worker/gateway; internal/platform e identity; migrations, queries, sqlc, go.mod/go.sum.
- `contracts`: OpenAPI, convenções e schemas de eventos/realtime.
- `infra`: Compose, imagem multi-stage Go e collector.
- `docs`: auditoria, overview, fronteiras, workflow, P2P, escopo, governança, registro admin e quatro ADRs.
- Raiz: README, Makefile, ignores, `.env.example`, scripts e workflow CI.

## 4. Versões

Selecionadas e executadas: **Go 1.27.3**, **Flutter 3.47.8**, **Dart 3.13.7**. SDK Flutter temporário na tag oficial, framework `737ba8f885dc774b53b442759999a312c9461e4e`; aparece como `user-branch` por checkout de tag, não por usar canal experimental. SDK compartilhado original preservado (Flutter 3.41.9/Dart 3.11.5 e Go host 1.26.3). Go usa toolchain automática fixada pelo módulo.

sqlc 1.31.1; Riverpod 3.4.3; go_router 18.1.1; Dio 5.11.1; secure storage 11.2.0. Dependências Go resolvidas no go.sum e mobile no pubspec.lock. SDKs nativos detectados: Android build-tools 36.0.0, Java 17, Xcode 26.3 e CocoaPods 1.16.2. Toolchain instalada não substitui build nem teste em aparelho.

## 5. Verificações efetivamente executadas

| Verificação | Resultado observado |
| --- | --- |
| Go gofmt, vet e `go test ./...` | Passaram; testes focados de configuração, probes, erros e contratos HTTP |
| Sanitização de logs HTTP | Teste passou: query/header sensíveis de teste omitidos, status e correlação preservados |
| OpenAPI | Especificação validada com kin-openapi; respostas 200/503 dos probes validadas nos testes |
| JSON Schemas | Envelopes events/realtime compilados e validados como schemas draft 2020-12 |
| sqlc | Código gerado com 1.31.1, recompilado e regenerado sem diferenças |
| Flutter pub get e format | Dependências resolvidas; `pub get --enforce-lockfile` passou e segunda checagem de formato teve zero alterações |
| Flutter analyze | Passou, `No issues found` |
| Flutter tests | 3 passaram: configuração segura, recuperação de link desconhecido e tema escuro com fonte ampliada |
| Compose config e build | Passaram; API, PostgreSQL, Redis e RabbitMQ alcançaram health saudável, inclusive em primeira inicialização com volumes novos e portas/projeto sobrescritos |
| Migrações goose | status/down/up executados; rollback removeu tabelas técnicas e preservou PostGIS |
| SQL transacional/inbox | Smoke inseriu dados sintéticos dentro de transação revertida; duplicata ignorada e nenhum efeito persistido após rollback |
| Probes reais e Redis | Health 200; readiness 200, 503 com Redis parado, 200 após recuperação |
| Shell scripts/ignores | `sh -n` passou; `.env` e configurações geradas nativas ignoradas |
| Inspeção de segredos | Busca limitada a padrões conhecidos de chaves privadas, tokens GitHub e access keys nos arquivos versionáveis não encontrou ocorrências; não equivale a auditoria completa |
| Exportação OTLP | Passou com Collector real: resumo `resource spans: 1, spans: 1` após requisição com traceparent amostrado; teste focado também confirmou `/v1/traces` |
| Encerramento gracioso | SIGTERM via `docker compose stop api` terminou com log estruturado `api stopped` e flush do trace recebido pelo Collector |
| APK debug | Passou: `flutter build apk --debug --dart-define=FLOW_ENV=test --dart-define=API_BASE_URL=https://api.example/`; artefato local em `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`, ignorado no Git; não instalado em aparelho |
| iOS/aparelhos físicos/Mapbox | Não executados; roteiro manual documentado |
| GitHub Actions remoto | Workflow criado; não executado nesta sessão, sem commit/push |

Falhas corrigidas durante a execução: primeiro build Docker iniciou antes da consolidação do go.sum; nova execução compilou. Probe inicial PostgreSQL usava socket e permitia falso positivo durante initdb; ajustado para TCP loopback e validado com volumes novos. Teste de contrato tinha caminho relativo incorreto; corrigido e reexecutado com sucesso. Exportador OTLP inicialmente usava `/`, gerando 404 no Collector; passou a compor `/v1/traces`, com teste focado de envio/recebimento HTTP real e sanitização de falhas de exportação. Sandbox bloqueou cache Go/runtime Flutter/socket Docker; verificações necessárias foram executadas com autorização de acesso externo ao sandbox.

## 6. Riscos/limites

Legado e marca final ausentes; Mapbox não auditável. Ícones Flutter e IDs `com.example` são scaffolds, não marca/IDs de release; assinatura de máquina removida e release Android não usa chave debug automaticamente. Associação nativa de links exige domínio/IDs/certificados verificados. SecureStore ainda não foi comprovado em Keychain/Keystore físicos. Sem autenticação real, relay, retenção automática, P2P ou admin. Observabilidade é fundação de traces/logs, sem dashboards/alertas/SLO de produção. Compose local não é arquitetura de deploy produtivo.

LGPD exige validações de produto/privacidade e responsáveis formais, além dos controles técnicos. Políticas de retenção são propostas, sem prazos legais presumidos. Nenhuma publicação está autorizada.

Após a validação, os contêineres/rede das stacks locais `flow` e `flow-pr00-fresh` foram encerrados; volumes preservados. Reiniciar com `make up`. `.env` local está ignorado e contém somente segredos aleatórios de desenvolvimento. Não houve instalação em aparelho, commit, push ou alteração de outro projeto.

## 7. Status de conclusão

**Fundação implementada, com homologação final condicionada. PR-00 não pode ser declarado integralmente concluído quanto à preservação/modernização do legado enquanto seu código estiver indisponível.** Itens técnicos com evidência estão acima; itens externos não foram omitidos nem simulados. Os critérios da Definition of Done relativos a preservação, marca e regressões dependem da entrega correta ou de uma decisão explícita de reinício sem legado.

## 8. Critérios exatos para PR-01

1. Disponibilizar o código Rolezin e concluir baseline/regressões, ou registrar decisão explícita de produto de seguir com base nova sem preservação. O remoto vazio não constitui essa autorização.
2. Confirmar bundle/application IDs, domínio de links, assets aprovados e signing de desenvolvimento; ícones de scaffold não podem seguir para publicação.
3. Reproduzir `make up`, `make smoke`, `make backend-check`, `make contracts`, `make sqlc` sem drift e `make mobile-check` nas versões fixadas; executar workflow remoto quando commit/push forem autorizados.
4. Validar instalação/execução em Android e iOS físicos, SecureStore e ligações de ambiente; executar regressões Mapbox se legado existir. Universal/App Links verificados precisam de evidência antes de usar callback de autenticação.
5. Revisar contratos Welcome/Registro/Login, estratégia de credenciais/verificação, sessão/renovação/revogação, erros, limites antiabuso e autorização antes de implementar endpoints. Nenhum contrato de login foi inventado no PR-00.
6. Aprovar inventário de dados Identity, avisos, base legal, política de menores, retenção e responsável/canal de privacidade antes de onboarding real; atualizar capacidades administrativas no PR-01.

O desenvolvimento dos contratos PR-01 pode usar a fundação agora; isso não remove os gates de integração/homologação acima.
