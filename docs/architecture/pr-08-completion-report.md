# PR-08 — relatório de conclusão local

Data: 2026-11-09. **PR-08 tecnicamente concluído localmente**, com dependências externas e homologação física separadas abaixo. Sem commit, push, merge, reset, descarte ou deploy externo.

## 1. Estado inicial do Git

Branch main, HEAD `da69b92ae8858c7ec5f3242dbff1959aaddde8c3`; index e árvore limpos na auditoria inicial, conforme [registro](pr-08-initial-review.md). HEAD permaneceu igual; entrega em alterações locais não staged. Migrações 00001–00009 e configurações privadas preservadas. Nenhum segredo incluído em contratos, fixtures, documentação ou novos arquivos de configuração.

## 2. Arquivos alterados

A lista abaixo compreende implementação Go/SQL/sqlc/contratos, componentes Flutter compartilhados, navegação, testes, CI/Makefile/smoke e documentação; não inclui os artefatos de build ignorados.

- `.github/workflows/ci.yaml`
- `Makefile`
- `README.md`
- `apps/mobile/lib/core/navigation/router.dart`
- `apps/mobile/lib/features/event_space/event_space_page.dart`
- `apps/mobile/lib/features/experiences/presentation/pages/experience_detail_page.dart`
- `apps/mobile/lib/features/social/social_compose_page.dart`
- `apps/mobile/lib/features/social/social_page.dart`
- `apps/mobile/lib/features/social/social_repository.dart`
- `apps/mobile/lib/features/social/social_widgets.dart`
- `apps/mobile/test/event_space_contract_test.dart`
- `apps/mobile/test/event_space_test.dart`
- `backend/cmd/api/main.go`
- `backend/cmd/contractcheck/main.go`
- `backend/cmd/social-moderation/main.go`
- `backend/internal/eventspace/http.go`
- `backend/internal/experiences/integration/event_space_flutter_test.go`
- `backend/internal/experiences/integration/event_space_test.go`
- `backend/internal/experiences/integration/experiences_test.go`
- `backend/internal/participation/http.go`
- `backend/internal/participation/members.go`
- `backend/internal/platform/database/dbgen/event_space.sql.go`
- `backend/internal/platform/database/dbgen/models.go`
- `backend/internal/platform/database/dbgen/querier.go`
- `backend/internal/platform/database/dbgen/social.sql.go`
- `backend/internal/social/graph.go`
- `backend/internal/social/http.go`
- `backend/internal/social/lists.go`
- `backend/internal/social/moderation.go`
- `backend/internal/social/service.go`
- `backend/internal/social/space.go`
- `backend/migrations/00010_event_space.sql`
- `backend/queries/event_space.sql`
- `backend/queries/social.sql`
- `contracts/README.md`
- `contracts/events/event-space-payload.schema.json`
- `contracts/openapi/flow.yaml`
- `docs/admin-capabilities.md`
- `docs/architecture/pr-08-completion-report.md`
- `docs/architecture/pr-08-initial-review.md`
- `docs/architecture/system-overview.md`
- `docs/decisions/0013-event-space-context-authorization.md`
- `docs/features/event-space.md`
- `docs/features/participation.md`
- `docs/features/social.md`
- `docs/privacy/data-governance.md`
- `scripts/smoke.sh`

## 3. Modelo de dados e migração

Migração aditiva00010_event_space.sql. Um espaço lógico por UUID da Experience, sem tabela duplicada de agregado/lifecycle e sem backfill de posts. settings, moderators, restrictions e report_reviews guardam somente dados adicionais. Posts EVENT_SPACE exigem SPACE/Experience; PERSONAL/EXPERIENCE_PUBLIC não mudam de audiência. local_hidden independente em posts/comments. Índice contextual por experiência/created_at/ID; trigger de Participation revoga papéis com audit/outbox. Rollback10→9 testado no banco isolado, preservando Social anterior e mídia, inclusive remoção do índice novo. Down remove apenas posts do novo contexto: não é procedimento de reversão sem perda de dados de produção.

Stack local principal: antes versão9, depois10; uma conta e zero experiências/posts/capas/assets antes e depois. Nenhum dado de demonstração criado no banco principal. API/worker/PG/storage/Redis/RabbitMQ saudáveis após `make mobile-local`. Configuração privada/Mapbox/Apple local e fluxo temporário de login preservados.

## 4. Contratos e endpoints

OpenAPI1.7.0:92→99 operações. GET resumo, feed, gallery, participants, reports, hidden e POST moderation sob `/v1/experiences/{experienceId}/space`. Publicações/interações/reports/upload/streaming continuam nas rotas Social. SocialInput/Post têm enums e capacidades explícitos; cinco comandos Participation recebem reason opcional, mantendo `{}` compatível. Comparação estrutural confirmou que demais paths/schemas anteriores permanecem iguais. JSON Schema de payload Event Space v1 e validação no contractcheck. Fixtures autenticadas existem somente no bridge de testes.

## 5. Matriz de autorização

[Matriz completa](../features/event-space.md#matriz-autoritativa). PUBLIC/UNLISTED não membro: somente prévia, sem posts/galeria/lista/contagem nominal. PRIVATE não membro/convite pendente:404. Criador e CONFIRMED elegíveis: leitura; escrita somente PUBLISHED antes de ends_at, sem pausa/restrição. Interesse/PENDING não autorizam. Moderador precisa nomeação e CONFIRMED atuais. DRAFT sem UGC; ENDED/CANCELLED/ARCHIVED somente leitura histórica autorizada. Remoção/cancelamento/block/conta/restrições/moderação reavaliados; autorização histórica não cria acesso novo. Check-in não é exigido. Denúncia/moderação/exclusão própria mantêm políticas explícitas de segurança/direitos.

## 6. Participation e Social

Um único cadastro de membros e um único conjunto de posts/comments/likes/media/reports. O serviço Social compartilhado aplica a política de contexto; novo handler apenas expõe o boundary. Participation remove/block/unblock também revogam no histórico anteriormente publicado, sem reabrir inscrição/aprovação. Motivos entram no audit existente. Papel é desativado por trigger ao perder CONFIRMED/block; reconfirmação exige nomeação nova. Restrição local não suspende conta e preserva leitura.

## 7. Feed, galeria e moderação

Feed/galeria/listas com snapshot e cursor HMAC, default20/max50, seção/experiência/usuário/sessão/limite vinculados,15min. Consulta SQL em lote e documentos/agregações existentes, sem N+1 de aplicação; sem alegar benchmark de carga. Galeria usa os mesmos assets READY e abre post original. HIDE/RESTORE de posts/comments são locais; RESTRICT/ALLOW, GRANT/REVOKE, PAUSE/RESUME e REVIEW têm escopo/motivo/audit/outbox. Revisão local não resolve denúncia global; dados do denunciante/body não são exibidos. CLI separada oferece space/hide-space/show-space sem HTTP admin; space inspeciona a Experience associada. Restaurar não supera moderação global/lifecycle/exclusão.

## 8. Flutter

Detalhes → Event Space real, cabeçalho contextual, Mural/Mídia/Participantes e ferramentas só pelas capabilities retornadas. Cards/autor/compositor/player compartilhados com Social; comentários usam detalhe Social existente e permitem moderação contextual. Compositor fixa EVENT_SPACE/SPACE sem seletor de audiência pública. Prévia reutiliza ParticipationPanel. Estados reais de erro/vazio/read-only/revogação e atualização manual. Player ao toque, sem autoplay, descarte ao navegar/background/trocar aba/conta. Sem aba Chat fictícia. Corrigidos problemas de lifetime do store ao trocar abas e de Hero ao abrir/retornar do compositor, detectados pelos testes.

## 9. Segurança, privacidade e revogação

Identity/sessão → Experience → post → comentário/mídia. Mutações e Participation/lifecycle compartilham o lock da Experience; autorização contextual é reavaliada antes dos recibos. Teste determinístico mantém remoção com lock, observa a mutação aguardando e verifica404/nenhuma curtida persistida depois do commit. Denúncias contextuais também usam guard de leitura; comentários de autores removidos não são alvos indevidamente visíveis por URL alternativa.

Conteúdo EVENT_SPACE não aparece em feed/profilagem pública, inclusive para observador membro. Participantes mínimos sem check-in/telefone/federação. Assets privados usam capabilities30s e ACL/sessão/versão atual em cada GET/range; testes reais comprovam retirada após HIDE e remoção. UI separa conta/experiência, cancela resposta antiga e limpa dados em background/saída/sessão/TTL absoluto≤30s, sem renovar páginas antigas ao paginar. Sem polling/realtime neste ciclo; bytes já entregues não são recuperáveis remotamente. [Inventário](../privacy/data-governance.md) atualizado, com retenção compartilhada e dependências de governança explícitas. Arquivar não autoriza retenção indefinida nem expurgo automático novo.

## 10. Testes executados e resultados

| Verificação final | Resultado e evidência local |
| --- | --- |
| `make backend-check` | gofmt/vet/test de todos os pacotes Go aprovados; `/private/tmp/flow-pr08-backend-check.log` |
| `make sqlc` | bindings regenerados pelo sqlc fixado; `/private/tmp/flow-pr08-sqlc.log` |
| `make contracts` + comparação estrutural | OpenAPI e schemas aprovados;92→99 operações, somente extensões previstas; `/private/tmp/flow-pr08-contracts.log` |
| PG/PostGIS/S3 reais |16 testes únicos Event Space(6), Participation(4), Social(6) aprovados em12,579s; `/private/tmp/flow-pr08-regression.log` |
| Suspensão de conta adicional | Caso contextual ampliado aprovado isoladamente em2,810s com bootstrap; `/private/tmp/flow-pr08-account-test.log` |
| Bridge Flutter/Dio↔Go/OpenAPI/PG | Fluxo privado real aprovado,21,478s incluindo bootstrap; `/private/tmp/flow-pr08-contract-bridge.log` |
| Flutter direcionado |39 testes (8 Event Space e31 regressões Social/Participation/Experiences) aprovados; `/private/tmp/flow-pr08-mobile-tests.log` |
| Flutter analyze | Sem issues,8,7s; `/private/tmp/flow-pr08-analyze.log` |
| Android debug | APK aprovado,assembleDebug38,2s; `/private/tmp/flow-pr08-build-android.log` |
| iOS debug/simulador sem assinatura | Runner.app aprovado,Xcode78,2s; `/private/tmp/flow-pr08-build-ios.log` |
| Runtime local | healthz/readyz200; Space sem sessão401; fixture404; migração10 e contagens preservadas |
| Revisão estática | git diff --check e sh -n scripts/smoke.sh aprovados; HEAD inalterado |

Cobertura inclui PUBLIC/UNLISTED/PRIVATE, DRAFT/ENDED/CANCELLED/ARCHIVED, interesse/PENDING/convite/CONFIRMED, criador/moderador/removido/block/suspensão, local/global moderation, comentários/likes/reports/IDs de outro espaço, paginação/galeria/mídia/range, concorrência, recibo após revogação, auditoria e schemas de eventos reais. Up/down/up10 e fronteiras anteriores usam somente DB flow_experiences_test/bucket flow-experiences-test. Não foi executado smoke destrutivo no banco principal. CI de infraestrutura inclui o novo bridge; os testes Go integram a suíte existente.

Os testes Flutter cobrem entrada pelos detalhes/retorno no tema escuro, prévia/404 sem buscar feed, criação privada, curtida, comentário/moderação, galeria/player/disposal, roster, motivo/ações,320px/texto200%, memórias, rede, perda de participação, background, logout e TTL sem polling. Falhas intermediárias de fixtures/rolagem/Hero/lifetime foram corrigidas; resultados finais acima são aprovados. Não há evidência nova de homologação física.

Artefatos locais ignorados: `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk` e `apps/mobile/build/ios/iphonesimulator/Runner.app`. SDK fixado no repositório, Flutter3.47.8/Dart3.13.7; usar flutterw e evitar caminhos temporários de SDK.

## 11. Pendências externas e limitações

Homologar com duas contas/aparelhos físicos: upload/imagem/vídeo real, acessibilidade/leitor de tela, memória/bateria, rede ambígua, remoção remota durante visualização e retomada. Builds/simulador não equivalem a essa evidência. Medir consultas/filas/custo sob carga real. Aviso KGP herdado do plugin Mapbox apareceu no Android, sem impedir o build; dependências não foram alteradas neste PR.

Produção continua dependente de IDs/assinaturas/distribuição, SMS/Google/Apple, HTTPS/universal/app links, marca/URLs legais aprovadas e operação de moderação/privacidade/direitos/retention/backups/menores/monitoramento. Este contexto não exige novo fornecedor/token. Conteúdo ativo e relações de configuração/papel persistentes precisam prazo/processo de eliminação aprovados; histórico não significa retenção ilimitada. Exportação/eliminação completa de conta e cópias externas não são prometidas. Nenhum deploy externo efetuado.

## 12. Capacidades administrativas

[ADM-052–057](../admin-capabilities.md): consulta/diagnóstico, denúncias, suspensão/restauração, revogação/histórico de responsáveis, retenção/exposição/processamento de mídia e auditoria/indicadores. Cada capacidade distingue operação atual de permissão/UI futura e exige escopo/caso/auditoria inclusive de leitura. Sem painel geral nem poderes globais a moderadores locais.

## 13. Status técnico

**PR-08 tecnicamente concluído localmente**, com implementação, migração aplicada, contratos, integração Flutter/Go, verificações e builds aprovados. Alterações disponíveis para revisão, sem commit/push/merge/deploy externo. Conta, dados anteriores, configurações e fluxo temporário de acesso preservados.

Para atualizar o iPhone, com Mac e aparelho na mesma rede, a partir de apps/mobile:

```sh
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

A execução física desse comando e a homologação do novo fluxo no aparelho não foram realizadas neste ciclo.

## 14. Preparação para PR-09 — Chat e Realtime

Reutilizar UUID da Experience, Participation e ACL/lock atuais; fatos eventspace/participation/social têm IDs mínimos e event_id para deduplicação. Conexões futuras precisam autenticação/revalidação/revogação ativa, audiência atual na entrega, ressincronização autorizada e presença efêmera com retenção própria. Não inferir autorização de claims antigas ou de ter recebido evento. Nenhum transporte de chat, mensagem, presença contínua, DM, push, story ou P2P foi iniciado neste PR.
