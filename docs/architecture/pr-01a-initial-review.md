# Verificação inicial — PR-01.A

Data: 28/10/2026. Branch `main`, HEAD `0ac52f7e057fe4a7b24286cd006ddf574bec1701` (`first commit`), workspace limpo antes das alterações. Nenhum AGENTS.md local encontrado.

PR-00 contém um módulo Go 1.27.3, API net/http/chi, pgxpool, sqlc 1.31.1, goose, PostGIS, Redis, RabbitMQ e probes separados. SQL em `backend/queries`, migrações numeradas em `backend/migrations`, código gerado em `internal/platform/database/dbgen`. Outbox/inbox estão disponíveis; não há relay implementado. Erros usam `{error:{code,message,request_id}}`. Logs omitem corpos, URLs e credenciais. Identity possui somente interfaces sem implementação.

Foram revisados OpenAPI, Compose, CI, schema técnico, governança, registro administrativo e ADR mobile. Nenhuma configuração de Twilio/SMS, Google, Apple ou chaves Identity foi identificada em nomes de variáveis presentes no ambiente ou `.env`; valores não foram exibidos. Validação externa dependerá dos pré-requisitos documentados. Nenhum envio SMS será simulado no runtime.

Decisão expressa do usuário neste ciclo: Flow é implementação nova e Rolezin está permanentemente substituído. Não pesquisar, migrar ou recuperar legado. Não executar testes físicos nem alterar telas Flutter. Essa decisão substitui o gate de preservação do relatório histórico PR-00, sem apagar suas evidências.

Plano de integração: módulo Identity dentro do monólito, migração incremental 00002, queries sqlc, contratos HTTP antes da integração mobile. PostgreSQL permanece autoritativo também para limites de abuso; indisponibilidade Redis não remove autorização, revogação ou quotas. Sessões usam credenciais opacas aleatórias, segredos de alta entropia hashados, refresh rotativo e histórico de família para detecção de replay. Provedores externos reais, doubles somente em testes de fronteira e PostgreSQL real para concorrência/transações.
