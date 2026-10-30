# Revisão inicial — PR-02.A

29/10/2026. Branch `main`, rastreando `origin/main`; HEAD `6b8cc2b846092d223a4ac4200d9d3e2edf5e8119`. `git status --short` vazio antes de qualquer edição: não há mudanças PR-01 pendentes. Este ciclo não fará staging, commit, push, merge ou deploy. Alterações posteriores a esse baseline pertencem ao PR-02.A, salvo novas alterações explícitas do proprietário.

Lidos os relatórios de conclusão PR-00, PR-01.A/B/C, fronteiras dos módulos, ADR de contratos/transações, OpenAPI, envelopes, registry administrativo, autenticação/sessões, migrations/queries/sqlc, composição da API, Compose, scripts de validação e CI. Não há AGENTS.md aplicável. O legado foi encerrado por decisão de produto; provedores/IDs/branding externos ainda não existem e não bloqueiam este domínio.

## Base e decisões de integração

- Chi/net/http; pgx com transações e sqlc; erros seguros com request_id; no-store e logs sem URL/corpo/header. Reutilizar o middleware Identity, expondo sua composição para módulos, e uma operação Identity de elegibilidade dentro da transação. Experiences não consulta tabelas Identity diretamente.
- Migrações atuais 00001 (plataforma/PostGIS/outbox/inbox) e 00002 (Identity). Acrescentar 00003 para Media mínimo e Experiences; rollback isolado antes de Identity. Não alterar migrations aplicadas.
- Nenhum upload real existe. Implementar S3 SigV4 com autorização temporária, área de staging, confirmação por leitura/decodificação limitada e cópia reencodificada em chave que o cliente não pode escrever. Bucket privado; acesso a capa mediado pela autorização da experiência. Validar com servidor S3 compatível real local, sem depender de credencial de nuvem.
- Draft parcial; publicação validada; agenda com instantes UTC e IANA; ponto geography SRID 4326. Começar com experiência física, sem antecipar online/chat/participação.
- Visibilidade explícita e immutable após publicação; PRIVATE apenas criador, UNLISTED somente acesso direto autenticado. Projeção pública derivada do estado autoritativo, sem janela de consistência eventual na autorização.
- Versionamento otimista, idempotência durável, quotas PostgreSQL e auditoria/outbox na mesma transação. Categorias persistidas e habilitáveis; restrições de publicação/moderação com fronteira definida, sem painel administrativo.

## Validação prevista

Fmt/vet/testes focados, contratos concretos, geração sqlc repetível; banco exclusivo `flow_experiences_test` para up/down/up, PostGIS, HTTP/autorização, concorrência, quotas, idempotência e atomicidade. Upload/validação/ownership/limpeza contra S3 real local. Regressão Identity afetada pela nova migration e composição. Nunca truncar/reverter o banco principal com dados. Documentar resultados observados e pendências externas separadamente.
