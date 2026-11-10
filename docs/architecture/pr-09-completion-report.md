# PR-09 — Chat e Realtime: conclusão técnica local

Data: 2026-11-10. Chat contextual implementado e validado no ambiente isolado. **Pronto para revisão local**, com ativação da API/banco principal e homologação física pendentes. Nenhum staging, commit, push, merge ou deploy realizado.

## 1. Estado inicial do Git

Branch main, HEAD `c74379e1bf7c30efd32470e078a868f421ec666c`, index e árvore limpos na auditoria inicial. [Registro](pr-09-initial-review.md). HEAD permanece igual; alterações locais não staged. Configurações privadas de Identity, Mapbox, assinatura e rede preservadas; migrações1–10 sem edição.

## 2. Arquivos alterados

- `.env.example`
- `.github/workflows/ci.yaml`
- `Makefile`
- `README.md`
- `apps/mobile/lib/features/event_space/chat_controller.dart`
- `apps/mobile/lib/features/event_space/chat_panel.dart`
- `apps/mobile/lib/features/event_space/chat_socket.dart`
- `apps/mobile/lib/features/event_space/chat_socket_io.dart`
- `apps/mobile/lib/features/event_space/chat_socket_stub.dart`
- `apps/mobile/lib/features/event_space/event_space_page.dart`
- `apps/mobile/test/chat_contract_test.dart`
- `apps/mobile/test/chat_test.dart`
- `apps/mobile/test/social_test.dart`
- `backend/cmd/api/main.go`
- `backend/cmd/contractcheck/main.go`
- `backend/cmd/social-moderation/main.go`
- `backend/go.mod`
- `backend/go.sum`
- `backend/internal/chat/http.go`
- `backend/internal/chat/service.go`
- `backend/internal/experiences/integration/chat_flutter_test.go`
- `backend/internal/experiences/integration/chat_test.go`
- `backend/internal/experiences/integration/experiences_test.go`
- `backend/internal/identity/transport/http.go`
- `backend/internal/platform/database/dbgen/chat.sql.go`
- `backend/internal/platform/database/dbgen/event_space.sql.go`
- `backend/internal/platform/database/dbgen/models.go`
- `backend/internal/platform/database/dbgen/querier.go`
- `backend/internal/platform/database/dbgen/social.sql.go`
- `backend/internal/social/graph.go`
- `backend/internal/social/moderation.go`
- `backend/internal/social/space.go`
- `backend/migrations/00011_event_space_chat.sql`
- `backend/queries/chat.sql`
- `backend/queries/event_space.sql`
- `backend/queries/social.sql`
- `contracts/README.md`
- `contracts/events/chat-payload.schema.json`
- `contracts/openapi/flow.yaml`
- `contracts/realtime/chat.schema.json`
- `contracts/realtime/envelope.schema.json`
- `docs/admin-capabilities.md`
- `docs/architecture/pr-09-completion-report.md`
- `docs/architecture/pr-09-initial-review.md`
- `docs/architecture/system-overview.md`
- `docs/decisions/0014-chat-persistence-realtime.md`
- `docs/features/chat.md`
- `docs/features/event-space.md`
- `docs/privacy/data-governance.md`
- `infra/compose/compose.yaml`
- `scripts/smoke.sh`


A lista inclui implementação Go, Flutter, SQL/sqlc, contratos, configuração de exemplo/Compose, CI, testes e documentação. Artefatos de build ignorados não fazem parte da entrega Git. Uma dependência Go direta adicionada: github.com/coder/websocket v1.8.15; nenhum framework novo no Flutter.

## 3. Modelo de dados e migração

Migração11_event_space_chat.sql, aditiva. UUID da Experience identifica o contexto. Tabelas rooms (contador), messages (UUID/autor/client ID/hash/body/created sequence/UTC/deleção/moderação), changes (ordem de alterações), connections (leases) e policy_clock (contador conservador de invalidação sem PII). Mensagens têm semântica própria; não duplicam posts, membros, perfis, mídia ou denúncias.

Checks de hash32bytes/texto≤3000/sequence positiva, unicidade por experiência/autor/client_message_id e índice de histórico por experiência/sequence. Reports Social acrescentam CHAT_MESSAGE; nenhuma publicação anterior muda de contexto/audiência. Rollback11→10 testado no banco isolado com registros anteriores de Event Space/Social preservados. Down remove dados novos de chat e seus reports; não é rollback sem perda de dados novos.

**Banco principal mantido na migração10, sem schema chat.** Consulta final mostrou uma conta, zero experiências e zero posts. As migrações11/up/down/up e fixtures foram executadas somente no DB flow_experiences_test/bucket flow-experiences-test. Não foi executado smoke destrutivo ou migração no banco principal.

## 4. HTTP e contratos WebSocket

OpenAPI1.8.0:99→103 operações. Novos GET resumo `/v1/experiences/{experienceId}/space/chat`, GET `/chat/messages` (cursor ou after), DELETE `/chat/messages/{messageId}` e GET `/chat/socket` para upgrade. Caminhos curtos são relativos ao mesmo `/space`. Send/ACK/entrega via WebSocket; resumo/histórico/recuperação/remoção por HTTP. Sem envio REST conflitante.

Envelope realtime1 e schema específico: chat.join/joined/leave, chat.message.send/ack/created/removed, chat.sync/reset/access.revoked/error/ping/pong. Correlation_id liga ACK/erro à frame recebida; experiência é vinculada à conexão/cursor, autor vem da sessão. Sequências são strings decimais. Frames reais validadas contra JSON Schema nos testes; schemas compilados pelo contractcheck. Comparação estrutural confirmou todos os paths anteriores iguais e somente SocialReportInput/SpaceReport com enum CHAT_MESSAGE ampliado.

## 5. Persistência e ordenação

PostgreSQL é fonte de verdade. Identity/sessão → Experience → contador/mensagem → audit/outbox na mesma transação. created sequence ordena histórico; change sequence ordena recuperação, incluindo remoções. UUID do aparelho não determina autor/ordem. ACK vem somente depois de commit. Reenvio de mesmo client_message_id/texto normalizado retorna a mesma mensagem; texto diferente gera idempotency_conflict. A chave é por espaço/autor e permanece enquanto o registro existir.

Histórico/recuperação default20/max50, cursores HMAC15min vinculados a modo/espaço/conta/sessão/snapshot/política. Receber uma frame não concede acesso. Cada processo lê alterações persistidas para suas conexões; não há armazenamento permanente em Redis Pub/Sub, novo serviço, banco ou relay. RabbitMQ/outbox mantém fatos duráveis mínimos existentes; texto/heartbeats não são publicados no broker.

## 6. Autenticação e autorização

Bearer Identity em Authorization no handshake nativo; nunca query/cookie/protocolo com credencial. AuthController/refresh existentes. Origin presente exige allowlist exata; cliente nativo sem Origin é permitido mediante autenticação. Produção exige TLS/WSS e proxy configurado. Ticket não foi necessário para esse cliente nativo; navegador não é habilitado pelo conector atual.

Mesmo event_space.can_read/can_write/can_moderate do PR08. Organizador/CONFIRMED atuais elegíveis; PUBLIC/UNLISTED visitantes, interessados, PENDING e convites privados pendentes sem histórico. DRAFT indisponível; futura/LIVE escrita; ENDED/CANCELLED/ARCHIVED histórico somente leitura. Pausa/restrição local, blocks/conta/moderação revistos. Check-in não é requisito.

Autorização na abertura/join/send/recuperação e durante conexão. Envio revalida após lock e antes da deduplicação. Escritor revalida credencial/espaço e reconsulta o documento de cada mensagem imediatamente antes de entregá-lo, incluindo blocks do autor/deleção/contenção; lote carregado não é cache de autoridade. Perda de acesso encerra lease/associação/conexão e limpa estado protegido no Flutter. Evento terminal é melhor esforço; fechamento sem frame também exige revalidação.

Clock transacional e leases no PostgreSQL permitem múltiplas instâncias sem memória compartilhada. Padrão de detecção ociosa1s, queries/timeouts e writes limitados; não é SLA nem instantaneidade absoluta. Bytes já em trânsito/recebidos não podem ser recolhidos. Falha de banco interrompe entrega. Teste de corrida determinístico comprova que envio aguardando remoção recebe404 e não persiste.

## 7. Reconexão, recuperação e backpressure

Backoff exponencial1–30s+jitter até499ms, máximo8 tentativas consecutivas sem sync, depois ação manual. Reconexão autenticada carrega snapshot e alterações posteriores ao cursor anterior; cursor inválido/expirado é descartado com fallback. Até10 páginas/500 alterações por tentativa; excesso gera aviso para consultar histórico, sem alegar recuperação ilimitada. UUID/sequence reconciliam ACK perdido, retries e frames repetidas/antigas. change_sequence impede ressuscitar removida por evento antigo.

Pendências próprias em RAM, mesmo client ID; sem confirmação após20s permite retry explícito. Não afirmar que ausência de ACK prova ausência de persistência. Memória até500 mensagens por janela/20 pendentes, paginação para trás com retorno às recentes. Background/saída encerram socket e limpam histórico; logout/troca de conta/revogação apagam também pendências/rascunhos. Watchdog6s sem frame válida. Sem fila em disco ou socket permanente no background.

Fila de entrada padrão16, limites de payload/frequência/conexões por conta/sala/processo, leases15s renovadas5s, conexão máxima10min e escrita serial com timeout2s. Parâmetros validados e repassados no Compose/.env.example. Overflow/consumidor lento encerra conexão; histórico persiste. Shutdown fecha sockets antes de encerrar HTTP. Counters/logs agregados de conexões/erros sem body/tokens/URLs/identificadores pessoais. Presença/last seen aproximados foram adiados para preservar o escopo e evitar contagem enganosa/rastreamento.

## 8. Moderação

Autor exclui mensagem própria conhecida, inclusive após remoção quando sessão/conta permitem. Organizador/moderador atual remove somente no próprio espaço, com motivo e auditoria; texto apagado no comando. Reports CHAT_MESSAGE reutilizam Social e revisão Event Space mínima, sem denunciante/body para moderadores. Revisão local não resolve denúncia global. CLI existente oferece chat-messages/hide-message/show-message/delete-message com credencial operacional/caso/operador separados e inspeção auditada. WITHHELD global não equivale à remoção definitiva nem restaura body excluído.

Fatos chat.message.created/removed no outbox têm somente IDs/sequência; denúncias usam fato Social existente. Revogação se baseia nos fatos/estados Identity/Participation/Event Space atuais, não em novo evento durável por heartbeat/conexão. Nenhum privilégio global foi concedido ao moderador local.

## 9. Flutter

Aba Chat real no Event Space, preservando Mural/Mídia/Participantes. Controller Riverpod central por espaço/sessão, transporte nativo testável fora dos widgets. Compositor fixo, histórico rolável, autor/horário, paginação, pendência/ACK/falha/retry, mensagem removida, somente leitura e moderação com confirmação. Rascunho próprio preservado em ressincronização; Semântica/tema Flow Material3.

Ponto transitório “Chat •” somente após abertura da sessão e mensagem nova em outra aba; sem contagem de não lidas inventada. Sem sockets duplicados em reconstruções, sem atividade artificial no background. Revogação conhecida também invalida os stores do espaço e player existente. Entrada de payload malformado não renderiza conteúdo arbitrário; documentos de outra experiência são rejeitados.

## 10. Segurança e privacidade

[Inventário](../privacy/data-governance.md), [guia](../features/chat.md), [ADR0014](../decisions/0014-chat-persistence-realtime.md). Texto processado pela plataforma, **sem E2EE**. Sem telefone/provedor/check-in/localização individual em documentos. TLS/WSS em produção; nenhum token em query/log. Cache isolado por conta/experiência e limpado na perda de autoridade/conexão.

Body90dias desde criação, filtrado na leitura e apagado pelo worker em lotes500; exclusão autorizada imediata do body. Metadados/hash/changes até180dias desde alteração pertinente, limpeza incremental; contador da sala sem UGC preserva ordem. Reports/audit180dias e quotas Social2dias; leases não formam histórico comportamental. Outbox segue governança existente sem apagar fatos pendentes. Backups, direitos, base legal/menores/contestação e eliminação dos agregados precisam política operacional aprovada antes de produção; arquivamento não é retenção ilimitada ou apagamento completo.

## 11. Testes executados e resultados

| Verificação | Resultado final / evidência local |
| --- | --- |
| Go fmt/vet/test de todos os pacotes | `make backend-check` aprovado; `/private/tmp/flow-pr09-backend-check.log` |
| sqlc fixado | bindings regenerados; `/private/tmp/flow-pr09-sqlc.log` |
| Contratos | OpenAPI/realtime/eventos compilados,99→103; paths anteriores preservados; mesmo log backend-check |
| Regressão PG/PostGIS/S3 |22 testes Chat(6)/EventSpace(6)/Participation(4)/Social(6) aprovados,18,512s; `/private/tmp/flow-pr09-regression.log` |
| Consumidor lento |1 teste adicional, escrita de rede bloqueada após upgrade, desconexão/active0/erro e histórico preservado;2,22s de caso,5,154s com bootstrap; `/private/tmp/flow-pr09-slow-consumer.log` |
| Integração Flutter/Dio/WebSocket↔Go/OpenAPI/PG |1 fluxo privado real aprovado,22,442s incluindo bootstrap; `/private/tmp/flow-pr09-contract-bridge.log` |
| Flutter direcionado |44 testes aprovados (5 Chat+39 regressões),13s; `/private/tmp/flow-pr09-mobile-tests.log` |
| Analyzer | Sem issues,7,7s; `/private/tmp/flow-pr09-analyze.log` |
| Android debug | APK aprovado,assembleDebug34s; `/private/tmp/flow-pr09-build-android.log` |
| iOS debug/simulador sem assinatura | Runner.app aprovado,Xcode69,2s; `/private/tmp/flow-pr09-build-ios.log` |
| Configuração/revisão | Compose config --quiet, sh -n smoke e git diff --check aprovados; HEAD inalterado |

23 testes backend direcionados únicos no total. Cobrem handshake/Origin/ACL PUBLIC/UNLISTED/PRIVATE, convite pendente, persistência/ACK perdido/idempotência/conflito, recuperação/cursor de outra sala/conta, ordenação concorrente, histórico, remoção/denúncia/moderação/CLI, quota/payload, sessão revogada/membro removido/blocks, lifecycle, duas instâncias independentes do handler compartilhando PG, shutdown, consumidor lento e outbox/audit/schema reais. Corrida de remoção versus envio comprovada com lock PG, sem depender de adivinhar tempo de execução. Up/down/up11 e fronteiras anteriores preservam marcadores de módulos anteriores no DB isolado.

Flutter cobre abertura/tabs/indicador, histórico/paginação, pendência/ACK/deduplicação, retry/backoff automático/fallback de cursor expirado, eventos antigos após remoção, logout, background/retomada, revogação, memórias, moderação e layout320px/texto200%/tema escuro/teclado. Bridge usa o conector WebSocket nativo e Dio reais, sem simular persistência. Fixtures de autenticação existem somente no binário de teste. Resultados finais aprovados após corrigir fixtures/contratos/layout e restaurar storage de testes; não declarar evidência física.

Artefatos ignorados em apps/mobile/build/app/outputs/flutter-apk/app-debug.apk e apps/mobile/build/ios/iphonesimulator/Runner.app. Wrapper flutterw mantém Flutter3.47.8/Dart3.13.7, sem usar SDK temporário.

## 12. Pendências externas

Sem deploy/instalação no aparelho neste ciclo. API/banco principal permanecem na versão anterior (migração10); ativar o PR09 exige revisão/autorização da atualização de API/worker/migrate. O endereço LAN anteriormente salvo não está disponível nesta rede; arquivos privados preservados, storage de testes em loopback. Preparar rede atual pelo fluxo mobile-local quando a atualização for autorizada, antes de usar o iPhone.

Homologar duas contas/aparelhos físicos, Wi-Fi↔móvel, persistência antes do ACK, background longo/retomada/token expirado/logout remoto, proxy WSS, limites e acessibilidade/memória/bateria. Duas instâncias de handler em teste não equivalem a homologação de cluster implantado. Medir custo de consultas por conexão/entrega e clock conservador sob carga real antes de ampliar escala. Não há benchmark/SLO/painel especializado entregue.

Produção ainda depende de domínio/TLS/WSS/proxy, IDs/assinaturas/distribuição, provedores Identity e governança de moderação/retention/backups/direitos/menores. Aviso KGP herdado do plugin Mapbox no Android não impediu build; dependências Flutter não foram alteradas. Navegador, presença, edição, anexos, DM, E2EE, P2P e push completo não fazem parte do escopo entregue.

## 13. Capacidades administrativas

[ADM-058–063](../admin-capabilities.md): inspeção auditada, denúncias/abuso, remoção/restauração/restrição, diagnóstico de entrega/conexão/incidentes, quotas/backpressure e retenção/revogação/auditoria. Cada capacidade distingue comandos atuais de permissão/UI futura, inclui escopo/caso/auditoria inclusive de leitura e separa moderação local/global. Sem painel administrativo geral.

## 14. Status técnico

**PR09 tecnicamente concluído no código e ambiente de testes, pronto para revisão local.** Implementação, persistência/ordem/ACK, autorização/revogação, integração nativa, contratos, documentação, validações e builds aprovados. Banco principal não migrado, API principal não atualizada, nenhum staging/commit/push/merge/deploy. Ativação operacional e homologação física permanecem pendentes explicitamente.

## 15. Preparação para PR-10 — P2P Gateway

Preservados contratos de mídia existentes (ID/hash/tamanho/MIME/variante/estado/ACL/revogação/fallback), sem usá-los no chat textual. Futuro PR10 deve definir autorização/consentimento/ameaças/distribuição/cache/eliminação e fallback próprios; não distribuir texto do chat nem usar presença/sockets como consentimento ou ACL permanente. Nenhum gateway, WebRTC, P2P, download de anexo ou tráfego peer-to-peer implementado neste ciclo.
