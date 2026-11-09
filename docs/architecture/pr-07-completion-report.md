# Relatório de execução — PR-07 Social

09/11/2026, America/Recife. Backend Go, PostgreSQL/sqlc, contratos e Flutter implementados diretamente no repositório. Nenhum staging, commit, push, merge, instalação física ou deploy externo pelo agente. **PR-07 tecnicamente concluído no ambiente local.** Homologação física e configuração de produção permanecem externas.

## 1. Estado inicial do Git

Branch `main`, HEAD `8f13da50397761baca1e88960fd4fe3e1667c0b3` (`implementa PR-06`), índice/árvore limpos. [Inspeção](pr-07-initial-review.md); snapshot OpenAPI/HEAD em `/private/tmp/flow-pr07-initial-*`, sem segredos. HEAD permaneceu igual durante o trabalho observado; migrations00001–00008 e configurações privadas preservadas.

## 2. Arquivos alterados

| Área | Entrega |
| --- | --- |
| Go Social | `backend/internal/social/{model,service,graph,lists,media,http,moderation}.go`, `config_test.go`; CLI `backend/cmd/social-moderation/main.go` |
| Banco | `backend/migrations/00009_social.sql`, `queries/social.sql`, extensão mínima `queries/flow_media.sql`, sqlc `dbgen/{social.sql,flow_media.sql,models,querier}.go` |
| Composição/Media | `cmd/{api,flow-media-worker,contractcheck}/main.go`, `internal/media/flow_assets.go`, Compose/Dockerfile, `.env.example`, Makefile e smoke protegido para9 migrations |
| Flutter | `features/social/{social_repository,social_page,social_compose_page,social_media}.dart`; router/Home e fronteira de upload/player existentes em Explore |
| Testes | `integration/social_test.go`, `social_flutter_test.go`, harness/rollback em `experiences_test.go`; `apps/mobile/test/social_test.dart`, `social_contract_test.dart` |
| Contratos/docs | OpenAPI1.6.0, payload Social v1 e README; guia Social, ADR0012, inspeção/este relatório, índices/README, governança e ADM-045–051 |

50 arquivos novos/modificados, todos sem staging. Nenhuma dependência Go/Flutter adicional nem mudança em pubspec/lock, SDK fixado, permissões nativas, Mapbox, IDs/assinatura local ou conta temporária. Sem dados sociais fictícios na aplicação.

## 3. Modelo de dados e migração

Migration00009 cria posts, comentários de primeiro nível, likes, follows, blocks, reports, restrições Social, audit, receipts e quotas, referenciando Identity/Experiences existentes. FK/constraints garantem unicidade/ownership transacional pela fronteira Go. Índices de feed/autor/grafo/comentários/retention; keyset e limites em consultas. Media reutiliza `media.flow_assets` com purpose FLOW/SOCIAL: Experience continua obrigatória somente para FLOW; associação Social exclusiva em post_media. Sem nova tabela de usuários ou fila/serviço audiovisual.

Rollback/up9→8 real preservou registro Flow/Experience/Identity e Participation; rollback das fronteiras anteriores também passou no banco isolado. Migrações anteriores imutáveis. Banco principal local chegou à versão9 preservando **1 conta,0 experiências,0 capas,0 Flows e0 posts**; não recebeu fixtures de teste.

## 4. Endpoints e contratos

**OpenAPI1.6.0:92 operações,27 novas Social**. Comparação estrutural dos65 endpoints/schemas anteriores contra HEAD sem diferenças. [Contrato](../../contracts/openapi/flow.yaml), [semântica completa](../features/social.md#contrato-http).

GET limits/feed/experience-options/blocks; CRUD posts, likes, comentários; perfil/posts/followers/following e follow/block PUT/DELETE; reports; upload/status/confirm e content de post/prévia de autor. Bearer existente; content usa capacidade30s vinculada à sessão e autorização atual. JSON/query estritos, envelope/no-store, limites20/50, cursor HMAC15min por conta/sessão/recurso/seção/modo/limite. Escritas de domínio com UUID de idempotência24h retornam somente ID; confirmação Media é naturalmente idempotente. ETag obrigatório na edição; replay não substitui GET autoritativo.

## 5. Feed

Seguindo consulta autores seguidos elegíveis; Descobrir somente PUBLIC. Recência created_at/UUID DESC e snapshot estável, sem ranking/score/engajamento simulado, fan-out ou cache compartilhado. Documento/contagens filtrados em SQL por observador, sem ida ao banco por card. Timeout3s e consulta limitada; sem alegação de benchmark de carga.

Autorização SQL compartilhada cobre todas as leituras e mídia. Cada página reavalia elegibilidade. No Flutter a validade absoluta da primeira página **não é renovada por paginação**, mesmo quando novas páginas chegam; expiração cancela a consulta em voo e remove dados até atualização. Background/conta/saída e ações próprias também invalidam/reconsultam.

## 6. Publicações, curtidas e comentários

PERSONAL e EXPERIENCE_PUBLIC, PUBLIC/FOLLOWERS, texto/mídia/combinação válidos. Texto padrão3000 (máximo5000), até4 mídias, publicação/interações limitadas30/min configuráveis. Edição somente body e janela padrão24h; contexto/audiência/mídia imutáveis. Exclusão apaga texto e revoga leitura/interações imediatamente.

EXPERIENCE_PUBLIC exige PUBLIC/PUBLISHED/VISIBLE, criador ativo sem restrição e autor organizador ou CONFIRMED atual. Participation contextual e blocks Social reavaliados; cancelamento/archive/moderação/audiência/remoção retiram acesso. Fim normal preserva relatos. PRIVATE/UNLISTED, inclusive opt-in de Flows, jamais habilitam exposição Social.

Likes únicos/idempotentes, contagens atuais por observador e concorrência PG; comentários paginados textuais≤1000, exclusão por autor ou autor do post, com moderação operacional separada. Sem chat/respostas aninhadas.

## 7. Grafo social e perfis

Follow/unfollow sem self/duplicatas; perfis reutilizam user_id/display_name/handle Identity, posts/contagens/listas autorizados e relações reais. Avatar/bio não inventados: domínio atual não fornece distribuição de avatar/perfil completo para este módulo.

Block simétrico remove follows mútuos e impede leituras/interações; listas/contagens/URLs alternativas filtram terceiros bloqueados. Unblock não restaura follows. Interações históricas permanecem e podem voltar a ser elegíveis após unblock, conforme política documentada. Lista de bloqueados retorna IDs para desbloqueio, sem abrir perfil bloqueado. Contas restritas/desativadas não aparecem como perfis ativos.

## 8. Mídia e processamento

Mesmo S3 privado/fila/worker/FFmpeg/lease/sanitização/quotas do PR-05. JPEG/PNG≤5MiB; MP4/MOV≤32MiB, duração verificada≤15s, H264/AAC/faststart/poster sanitizado. Upload não confia em extensão/MIME; somente READY do autor, purpose SOCIAL e asset exclusivo pode vincular a post. Nenhuma referência arbitrária de S3 ou asset Flow/capa aceita.

Status/preview real do autor antes de publicar, capability30s e revalidação por GET/range. Prévia anterior ao vínculo também passa a obedecer à política do post: não contorna moderação/exclusão. Revogação de sessão, troca de asset, bloqueio e retirada de post testados com S3/bytes reais. Sem redirect/presigned GET público. Staging/órfãos/deletados removidos pelo worker; tombstones/retention documentados e cleanup real testado. Bytes já entregues não são recuperáveis remotamente.

## 9. Moderação e segurança

Reports reais USER/POST/COMMENT, razões categóricas e deduplicação; sem contagem pública ou texto livre sensível. CLI `social-moderation` exige credencial DB separada, operador e caso: reports/post/posts, hide/show/delete-post, hide/show-comment, restrict/restore-user e resolve-report. Inspeções e comandos auditados/outbox transacionais; sem endpoint privilegiado ou impersonação. Credencial/OS/rede são fronteira operacional, segregação de papel/secret manager/revisão de acesso requer provisionamento de produção.

Locks Identity/par/post, ACL atual, constraints, rate persistido antes das transações e origem Identity. Audit/outbox sem texto/URL/token/código, payloads de eventos verificados contra schema/envelope. Restrição Social não suspende Identity nem altera assentos. Exclusão texto imediata; mídia órfã/post excluído após idade24h, staging expiração+1h, tombstones7dias, audit/reports180dias desde criação, receipts24h, quotas2dias. Manutenção limitada por minuto no worker, com retry após falha. Sem telefone/provedor/contatos/GPS preciso na superfície Social.

## 10. Integração Flutter

Rotas protegidas `/social`, `/social/new`, `/social/blocks`, `/social/posts/:id` e edição, `/social/profiles/:id` e seguidores/seguindo. Home recebe atalho. Mesmos Riverpod, Dio/Identity, go_router, Material3 e tokens Flow. Stores reutilizam cancelamento/geração/idempotência do ciclo anterior e acrescentam janela absoluta por rota Social.

Feed/abas/cursor/cards, perfil/relações, detalhe/likes/comentários, reports com motivo e confirmação de exclusão/bloqueio. Compositor conserva texto/chave na falha, configuração/seleção de experiências elegíveis real, gallery/preview/S3/status/retomada e prévia de vídeo processado. Descarte exige confirmação; conta/saída limpa rascunho e cache da prévia. Não anuncia sucesso antes de commit confirmado. Um player por rota, descarte serializado antes de abrir outro, vídeo sem autoplay/som, mídia sob demanda, pausa em background/saída/expiração e cancelamento de respostas antigas. Sem preload da timeline.

## 11. Testes e resultados efetivamente observados

| Verificação | Resultado |
| --- | --- |
| Go/sqlc/OpenAPI | gofmt, vet direcionado, testes Social/Media/Experiences/Participation/API e compilação CLI/worker aprovados; sqlc gerado; OpenAPI e todos os schemas validados; contratos anteriores preservados |
| Go/PG/S3/FFmpeg | Oito casos únicos de domínio pertinentes aprovados em rodadas focadas: seis Social e regressões de Flows/Participation. Sete casos11,092s; complemento cursor/comentários/contagens por observador0,39s e teste independente de eventos/cleanup0,05s. Segurança final de mídia/sessão/asset aprovada2,94s (suite6,874s) |
| Cobertura real | CRUD/ETag/replay, PUBLIC/FOLLOWERS, grafo/bloqueios/contagens, cursor ligado à sessão/modo, comentários/autorizações, concorrência12 likes, contextos proibidos e revogação Participation/cancelamento, PNG real/MIME falso, MP4 real/poster/range e recusa16s, ownership, URLs anteriores/moderação/deleção/sessão, limpeza S3, quotas, report/CLI/audit/outbox/rollback |
| Flutter/Dio ↔ Go/OpenAPI/PG/S3 | TestFlutterSocialContract aprovado25,05s (rodada28,651s): upload S3 real com confirmação assíncrona, ownership, FOLLOWERS, follow/likes/comentários/edição/reports/perfil/blocks/unblock/deleção através do repositório real |
| Flutter | **29 casos Flutter únicos pertinentes aprovados**:10 Social,5 Home e14 regressões Explore/Flows/Participation. Rodada final10 Social/8s, incluindo validade absoluta ao paginar e vídeo ao toque/sem autoplay/descarte; Home+8 casos Social13/19s na rodada anterior |
| Análise/builds | **Analyzer final sem issues,7,3s. APK Android debug final aprovado35,1s; iOS simulador debug final aprovado42,3s**, ambos após a correção de validade da paginação. Artefatos ignorados em `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk` e `build/ios/iphonesimulator/Runner.app` |
| Stack local | make mobile-local aprovado, migração9, API/worker saudáveis, healthz/readyz200; Social anônimo401, fixture404; contagens preservadas. Nenhum smoke destrutivo no principal |

Falhas encontradas foram corrigidas e revalidadas: constraint de comentário apagado; descarte Riverpod; confirmação de rascunho e pausa durante diálogo; ajuste de fixture de sessão respeitando revocation_reason; teste de scroll precisava aguardar tornar o autor visível antes do toque. Checagens/testes foram ampliados quando esses riscos ou alterações justificaram. Logs/artefatos em `/private/tmp/flow-pr07-*`, sem versionar secrets. Sem teste de carga, instalação/homologação física ou homologação de produção alegados.

## 12. Pendências externas

Roteiro de dois aparelhos/contas autorizadas, rede ambígua, galeria/vídeos reais, lifecycle/sessão/TTL/revogação remota, temas/leitor de tela/fluidez/memória/bateria em [Social](../features/social.md#validação-e-homologação). Produção ainda depende de IDs/assinaturas/distribuição, SMS/Google/Apple, HTTPS/universal links/app links, marca/URLs legais e operação de moderação/privacidade/retenção/menores/backups/monitoramento. Sem origem aprovada não há compartilhamento externo por link fictício. Aviso KGP do plugin Mapbox herdado não impediu APK e não alterou dependências neste ciclo.

## 13. Capacidades administrativas documentadas

[ADM-045–051](../admin-capabilities.md): gestão/restrição Social de usuários, busca e retirada de posts, investigação de denúncias, blocks/restrições, comentários/abuso, mídias/indisponibilidade e auditoria/retention/limites. Cada uma diferencia comandos reais da CLI de permissões/UI futuras, efeitos, escopo e auditoria. Sem plataforma administrativa geral.

## 14. Status técnico do PR-07

**PR-07 tecnicamente concluído localmente.** Implementação, backend real, contratos, integração Flutter/Go,29 testes Flutter pertinentes, analyzer, builds Android/iOS e stack local aprovados nas evidências acima. Nenhum commit/push/merge/deploy externo. Configurações privadas e dados existentes preservados. Para atualizar o app a partir de `apps/mobile`, com Mac/iPhone na mesma rede e stack local ligada:

```sh
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

## 15. Preparação para PR-08 — Event Space

Posts/comments/likes/post_media, versões, author IDs, eventos e Media reutilizáveis. Novo contexto futuro exige migração/ACL contextual explícita, elegibilidade atual e testes próprios; CONFIRMED e opt-in de Flows não concedem acesso automático. Não foi criado Event Space, comunidade, chat/DM, stories, push, IA, pagamentos ou P2P. Contrato de ID/hash/size/MIME/variant/estado/revogação/fallback documentado para PR-10, sem signaling/WebRTC.
