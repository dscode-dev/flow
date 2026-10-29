# Relatório de execução — PR-01.A

Execução iniciada em 28/10/2026, encerramento em 29/10/2026 (America/Recife). Implementação backend local; nenhuma alteração de telas, execução física Android/iOS, commit, push, merge ou deploy.

## 1. Estado inicial

Branch `main`, HEAD `0ac52f7e057fe4a7b24286cd006ddf574bec1701` (`first commit`), rastreando `origin/main`; workspace limpo. Go 1.27.3 e convenções PR-00 preservados. Verificação em `pr-01a-initial-review.md`. A decisão explícita de produto de criar Flow do zero foi registrada no ADR 0005; o legado não foi procurado e não é dependência deste ciclo.

## 2. Arquivos criados/modificados

- **Identity:** `internal/identity/{accounts,apple,challenges,config,crypto,errors,rate,service,sessions}.go`, interfaces atualizadas em context.go; `provider/{oidc,twilio}.go`; `transport/http.go`; testes unitários e integração separados por build tag, fixture RSA exclusiva de teste.
- **Persistência:** migration `00002_identity.sql`, `queries/identity.sql`, queries/models/interfaces sqlc gerados e go.mod/go.sum com go-oidc, JWT, libphonenumber e dependências mantidas.
- **API/operação:** registro das rotas no router PR-00 e composição em cmd/api; comando `cmd/identity-retention`; imagem Docker incluindo o comando; Compose e `.env.example` com parâmetros Identity; helper de chave local sem overwrite de valor existente.
- **Contratos:** OpenAPI 1.0.0, schemas concretos, erros/limites/idempotência por operação; convenção de evento com segmentos de domínio/fato.
- **Verificação:** scripts identity-test/init-identity-env; smoke atualizado para duas migrações e protegido contra contas/outbox existentes; Makefile e GitHub Actions com integração PostgreSQL real e teste de Redis indisponível.
- **Documentação:** ADRs 0005/0006/0007, feature Identity e especificação PR-01.B, revisão inicial/relatório, governança e registro administrativo. README/overview/fronteiras/workflow/escopo atualizados; documentos PR-00 preservados como históricos com aviso da decisão nova. Apenas README mobile foi atualizado; código Flutter intacto.

## 3. Modelo e migração

Schema identity com users (active/suspended/disabled/deleted), profiles mínimos, reserved_handles, auth_identities, devices, sessions, refresh_credentials, access_credentials, challenges, rate_limits, audit_events e provider_notifications. UUIDs internos v7, unicidade provider/subject e handle, FKs/checks/índices. PHONE persiste HMAC E.164, não telefone cru; desafio não guarda OTP, token externo ou autorização Apple.

Onboarding explícito, nome normalizado e handle ASCII reservado/único; sem gerenciamento geral de perfil. Sessão é família refresh; devices são registros do servidor, sem fingerprint. Nova migração pode ser revertida em banco isolado; rollback é destrutivo para dados Identity e não serve como procedimento de produção sem plano/backup. Smoke recusa usuários/eventos existentes.

## 4. API implementada

| Método | Operação |
| --- | --- |
| POST | `/v1/auth/phone/challenges`, `/v1/auth/phone/verify` |
| POST | `/v1/auth/oidc/challenges`, `/v1/auth/google`, `/v1/auth/apple` |
| POST | `/v1/auth/refresh`, `/v1/auth/logout`, `/v1/auth/reauthenticate` |
| GET / PATCH | `/v1/me` / `/v1/me/onboarding` |
| GET / DELETE / POST | `/v1/me/sessions`, `/v1/me/sessions/{sessionId}`, `/v1/me/sessions/revoke-all` |
| GET / POST / DELETE | `/v1/me/identities`, `/v1/me/identities/link`, `/v1/me/identities/{identityId}` |
| POST | `/v1/auth/apple/notifications` (JWS Apple, não bearer Flow) |

São 17 operações Identity, além dos probes existentes. Todos os contratos têm schemas/respostas, autorização, semântica de repetição e quotas documentadas. Não há senha, reset, login por username/password, CRUD Users ou admin placeholder.

## 5. Provedores

- **SMS:** adapter real Twilio Verify v2, HTTPS fixo, autenticação de servidor, início SMS e VerificationCheck ligado ao SID; timeout e erros sanitizados. Número E.164/BR por padrão, TTL, tentativas, cooldown e quotas duráveis número/origem/global/minuto/dia. Pedido aceito não prova entrega no aparelho.
- **Google:** coreos/go-oidc com JWKS oficial fixo e cache/rotação da biblioteca, RS256, issuer/audience/azp/exp/iat e nonce da challenge; somente sub verificado. Não depende de telefone nem faz merge por e-mail.
- **Apple:** ID token nativo com audience/issuer/assinatura/exp/iat/nonce, sem troca de código neste fluxo, sem depender de nome/relay. Notificações assinadas reais suportadas para revogar identidade/sessões e deduplicar jti; sem exigir exp ausente no formato documentado. Troca/revogação de OAuth tokens Apple por chave privada não foi inventada como feature.

## 6. Controles de sessão e identidade

Access/refresh aleatórios de 256 bits, hashes SHA-256 no banco, comparação constante de refresh e rotação transacional. Replay correto revoga família; segredo incorreto não permite revogar família alheia. Sem grace/retry do refresh antigo. TTLs configuráveis, expiração absoluta, múltiplos dispositivos e revogação própria/por dispositivo/todas. PostgreSQL verifica status e revogação em cada bearer/refresh; Redis não é autoridade nem fallback permissivo.

Vínculo/desvínculo exige sessão e autenticação recente; nova identidade tem prova independente ligada à finalidade/sessão. Conflitos não transferem ownership. Locks/constraints impedem cadastro duplicado e remoção simultânea da última identidade. Suspended/disabled/deleted negam acesso e não criam outra conta quando a mesma prova é reapresentada. Recuperação sem método restante tem procedimento conservador, sem bypass por perfil.

Eventos implementados são duráveis na outbox, junto com estado e auditoria. Não há relay RabbitMQ; nenhum evento foi declarado como publicado externamente. Logs e audit são separados de analytics, sem OTP, provider token, refresh, authorization code, telefone ou e-mail cru.

## 7. Verificações efetivas

| Check | Evidência/resultado |
| --- | --- |
| Go format/vet e testes focados | Rodadas de configuração/provedores/Identity e regressões HTTP/config PR-00 passaram; validações finais registradas abaixo |
| Criptografia Google/Apple | Fixtures RS256 com chave fixa e relógio controlado; aud/issuer/assinatura/exp/iat/nonce/azp e algoritmo incorretos negados; notificação Apple sem exp validada no formato documentado |
| Adapter SMS | HTTP controlado verificou início/check/SID, código correto/incorreto, 429/4xx/5xx e redaction; não foi delivery real |
| HTTP + PostgreSQL real | Cadastro e retorno uniforme, onboarding/reserva/unicidade, cadastro concorrente, consumo concorrente único OTP, expiração/exaustão, cooldown/resend e teto financeiro passaram |
| Sessões/vínculos | Refresh/rotação/replay, refresh simultâneo, expiração, logout, revogação uma/todas, reauth, conflito de dono e proteção concorrente da última identidade passaram |
| Restrições/Apple/auditoria | Status suspended/disabled/deleted negados, nonce errado negado, webhook revoga/deduplica, auditoria e logs sem secrets passaram |
| Redis realmente parado | Suite verificou conexão recusada e executou fluxos/quotas autoritativos sem Redis; script restaurou serviço ao sair |
| Retenção | Comando real executado somente no banco de teste; removeu histórico após janela e preservou refresh de sessão expirada recentemente |
| OpenAPI/JSON Schema | kin-openapi e envelopes v1 validados; respostas HTTP reais conferidas contra OpenAPI nos testes |
| Migrações up/down | Integração isolada e smoke reverteram 00002/00001 e reaplicaram; PostGIS preservado e Identity down não afetou outbox da fundação |
| Container smoke | API/dependências saudáveis, probes e recuperação Redis passaram na imagem Identity; imagem final recompilada inclui manutenção/revisão adicional |
| sqlc | Geração realizada; conferência final de drift registrada abaixo |
| Flutter/aparelhos físicos | Não executados, por escopo explícito; sem alteração de telas |
| Provedores reais | Não homologados: credenciais/client IDs não fornecidos; testes externos não foram declarados aprovados |
| GitHub Actions | Workflow atualizado; execução remota não realizada, sem commit/push |

Durante desenvolvimento, sqlc rejeitou referência ambígua de `id` no CTE de atualização de dispositivo; consulta foi qualificada e os checks e integrações seguintes passaram. Campos nulos de UUID foram ajustados para tipos pgtype corretos antes dos testes. Nenhuma falha foi contornada por fake DB, token permissivo ou bypass de OTP.

## 8. Dependências externas pendentes

**Homologação SMS bloqueada** por ausência de TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN e TWILIO_VERIFY_SERVICE_SID reais, settings de serviço/Fraud Guard/Geo Permissions/orçamento e número autorizado. É necessário observar recebimento e verificação com o proprietário; nenhuma entrega real ocorreu.

**Homologação Google bloqueada** por ausência de projeto/client IDs/audiences/azp aprovados, certificados/IDs de app e token real obtido pelo cliente com nonce. **Homologação Apple bloqueada** por ausência de App ID/bundle/client IDs aprovados, entitlement e configuração HTTPS de notificações. O fluxo ID-token selecionado não requer `.p8`/client secret no backend; não solicitar essas chaves sem definir futura troca/revogação de tokens OAuth.

Lista e procedimento completos em `docs/features/identity.md` e ADR 0007. Configuração ausente desabilita método com 503; nunca simula login ou SMS.

## 9. Privacidade e administração

Governança atualizada com inventário por tabela/finalidade/destinatários/prazos, HMAC como pseudônimo, retenção implementada e gates antes de dados reais. Registry ADM-003–012 registra consulta restrita, status/suspensão/restauração, sessões, provedores, abuso/delivery, audit search, suporte/recuperação, direitos e métricas/manutenção, com permissões/auditoria/UI/contratos/riscos/status. Plataforma admin e API privilegiada não foram implementadas.

## 10. Riscos e limites remanescentes

Credenciais e homologação externas; riscos inerentes a SMS; orçamento/custos/entregabilidade reais; SDK mobile com nonce; associação nativa/certificados e armazenamento seguro no cliente. Preservar/rotacionar chave HMAC com processo controlado; troca arbitrária quebraria lookup de PHONE. Proxies não têm headers de origem confiados: ajustar contrato de ingresso antes de tráfego público, sem aceitar X-Forwarded-For do cliente. Sessões limitadas exigem UX para session_limit.

Retenção precisa de aprovação de privacidade e agendamento operacional; auditoria não é WORM homologada. Política de tombstone/recovery/direitos, menores, avisos e base legal devem ser validados antes de uso real. Outbox não tem relay, e nenhuma promessa de produção/LGPD decorre da suite local. Não existe bloqueio por legado, pois a decisão de implementação nova já foi dada.

## 11. Status PR-01.A

**Backend funcional implementado e validado localmente, pronto para integração PR-01.B pelos contratos entregues.** Homologações SMS/Google/Apple permanecem explicitamente pendentes de configuração do proprietário, como previsto no escopo. Sem dependência de telas ou testes físicos neste ciclo. Checks finais e estado de encerramento são registrados abaixo antes da entrega.

## 12. Requisitos exatos PR-01.B

Implementar as telas e estados usando `docs/features/identity-mobile-integration.md`: três métodos sem senha, nonce obrigatório e sem hash duplo Apple, bearer Flow separado de ID token, refresh single-flight/rotação atômica, onboarding explícito, reauth/vínculos e revogação, tratamento 401/403/409/429/503 sem mocks ou bypass. Confirmar IDs/configuração nativa e SDKs compatíveis; prover credenciais e homologar fornecedores em ambiente apropriado. Aprovar privacidade/suporte/orçamento antes de pessoas reais. Não reabrir migração Rolezin ou exigir telefone após login social.

## Fechamento de verificação

Go format/vet e testes focados finais passaram; testes criptográficos incluem nbf futuro negado. OpenAPI e JSON Schemas válidos. sqlc 1.31.1 foi regenerado sem diferenças. A última integração executada passou em **4,328s**, com nove grupos principais e dez subcenários adicionais: quotas número/origem/minuto, limites de body, rejeição de atributos de identidade enviados pelo cliente, endpoint de senha ausente e header de origem forjado incluídos. O validador do harness foi corrigido para conferir o envelope 404 de uma rota ausente sem inventar operação OpenAPI; a rodada final passou.

Shell scripts passaram em `sh -n`; `git diff --check` sem erros; links locais da documentação existentes. Busca limitada de padrões de segredos não encontrou ocorrências fora da chave RSA de teste explicitamente declarada. Foram identificados 58 arquivos novos/modificados, sem alteração de código Flutter. Imagem final recompilada com sucesso: API/PostgreSQL/Redis/RabbitMQ saudáveis. Smoke HTTP final observou `/healthz` 200 alive, `/readyz` 200 ready, `/v1/me` 401 unauthorized e PHONE/GOOGLE/APPLE sem configuração retornando 503 provider_unavailable. O binário de retenção foi incluído na imagem; não houve tentativa de SMS/login real. Encerramento local preserva volumes e banco separado de teste; reinício via `make up`.

HEAD permanece `0ac52f7e057fe4a7b24286cd006ddf574bec1701`; workspace contém as alterações entregues, sem staging/commit/push/merge/deploy. Código Flutter não foi modificado nem foram executados testes físicos. Configuração local recebeu apenas chave HMAC aleatória por helper, ignorada no Git.
