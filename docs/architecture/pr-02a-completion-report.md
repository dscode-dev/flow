# Relatório de execução — PR-02.A

29/10/2026, America/Recife. **Implementação técnica local concluída**, pronta para integração Flutter PR-02.B. Nenhum staging, commit, push, merge ou deploy. Homologação/provisionamento de nuvem e terceiros permanecem externos ao aceite local.

## 1. Baseline Git e separação

Branch main, origin/main, HEAD `6b8cc2b846092d223a4ac4200d9d3e2edf5e8119`; workspace inicialmente limpo, sem pendências PR-01. [Revisão inicial](pr-02a-initial-review.md) registra fontes e arquitetura inspecionadas. HEAD preservado. Alterações deste ciclo: módulos Experiences/Media, extensão mínima de composição/elegibilidade Identity, migration00003/queries/dbgen, OpenAPI/event payload, Compose/SDK/CLI/scripts/CI e documentação. Nenhuma alteração Flutter/nativa ou configuração de provedor externo.

## 2. Modelo implementado

Agregado físico com UUIDv7, autor opaco, título/descrição/categoria, audiência/estado/moderação, agenda UTC/fuso IANA, ponto geography4326, venue/endereço, capacidade opcional, ticket HTTPS, capa READY própria, timestamps e versão. Draft parcial, normalização NFC/trim/limites, validações temporais/geográficas e catálogo persistido com nove categorias. Não há tabelas para presença, convites, compra ou feed.

## 3. Migrações e índices

`00003_experiences_media.sql`: schemas Media e Experiences, constraints/PK/FK/uniques, catálogo seed, idempotência24h, quotas por dia UTC, restrição de publicação, auditoria e bindings. READY exige metadados não nulos e verificados; duração SQL usa744 horas transcorridas, independente do timezone da sessão. Índices own por criação/ID, públicos por agenda/ID e categoria/agenda/ID, GiST geography parcial, cleanup e auditoria. Visões documents/discovery derivam do agregado, sem estado assíncrono. [Schema detalhado](experiences-database.md).

Up/down/up real validado em banco isolado, incluindo uma conta Identity sobrevivendo ao down exclusivo00003 e PostGIS/outbox preservados. Smoke final reverteu00003/00002/00001 e reaplicou em ambiente principal **vazio**, após guardas de dados, preservando PostGIS. Nenhuma conta/experiência real foi apagada.

## 4. Endpoints e contratos

OpenAPI **1.1.0**, 12 operações acrescentadas (31 totais com Identity/probes):

| Método | Path |
| --- | --- |
| GET | `/v1/experience-categories` |
| POST / GET | `/v1/experiences` |
| GET / PUT | `/v1/experiences/{experienceId}` |
| POST | `/v1/experiences/{experienceId}/publish`, `/cancel`, `/archive` |
| GET | `/v1/me/experiences` |
| GET | `/v1/experiences/{experienceId}/cover` |
| POST | `/v1/media/uploads`, `/v1/media/uploads/{mediaId}/confirm` |

Todas exigem bearer Flow; autoria/upload exige onboarding concluído. JSON estrito <=32KiB, erros estáveis/request_id, PUT substitui documento completo, Idempotency-Key UUID na criação/upload, ETag/If-Match nas mudanças. Paginação por cursor HMAC15min vinculado a principal/filtros/limite, padrão20/máximo100; filtros por estado próprio ou categoria/fase/distância pública. Sem total/snapshot longo. Responses/requests reais foram validados contra o OpenAPI na suíte.

## 5. Lifecycle e visibilidade

DRAFT editável/publicável; PUBLISHED permite corrigir título/descrição/ticket/capa antes do fim, protegendo agenda/fuso/local/venue/endereço/categoria/capacidade/audiência. Cancelar DRAFT ou PUBLISHED ainda em andamento; arquivar DRAFT/CANCELLED ou PUBLISHED encerrada. CANCELLED/ARCHIVED não republicam. Fases UPCOMING/LIVE/ENDED derivadas, sem cron de status. Publicação aceita LIVE e exige fim futuro, duração>0 até31d e início até366d.

PUBLIC/PUBLISHED/VISIBLE entra na descoberta enquanto fim futuro. UNLISTED somente acesso direto autenticado após publicar; PRIVATE somente criador. UUID não concede acesso privado. Histórico já publicado mantém ID/agenda/estado e redige detalhes de terceiros; WITHHELD retorna404 a terceiros. Draft cancelado/arquivado sem publicação continua privado ao autor. Participation/Invitations futuras devem fornecer autorização explícita antes de ampliar acesso.

## 6. Mídia e armazenamento

AWS SDK Go v2 com S3 SigV4 POST real; autorização5min fixa staging key/MIME/tamanho exato1..5MiB. Confirmação lê bytes limitados, valida JPEG/PNG <=4096px/lado e12MP, reencodifica sem metadados/trailer e grava em chave verified não autorizada ao cliente. READY e binding exigem mesmo dono; confirmação é idempotente. Sem URL arbitrária, vídeo/P2P ou fake upload.

Leitura de capa passa pela autorização da experiência e retorna bytes no-store. Bucket local privado SeaweedFS4.51: teste sem assinatura recebeu negação; MIME/tamanho/chave adulterados foram negados pelo S3. Sobrescrever staging depois da confirmação não mudou a capa verificada. Limite de duas confirmações simultâneas por instância evita fila/memória ilimitadas.

CLI `experiences-maintenance` implementa staging expirado+1h, órfãos>24h, tombstones>30d, idempotência24h, quotas>2d e auditoria>180d, sem apagar experiências/histórico/outbox pendente. Binding e cleanup usam locks. Limpeza S3 real de órfão preservou capa associada na integração. Bucket exclusivo de fixtures é limpo antes/depois dos testes; bucket de aplicação não é usado pela suíte.

## 7. Segurança, privacidade e consistência

Reutilizados middleware Identity e verificação PG de bearer/status/revogação. `identity.RequireCreator` mantém lock de conta/sessão dentro da transação de autoria, sem SQL Experiences lendo tabelas Identity. Ownership uniforme404, versões conflitantes412, quotas duráveis e restrição de publicação. Campos do servidor não são aceitos no Input.

Mudança de agregado, auditoria e evento são atômicos; criação inclui idempotência no mesmo commit. Teste forçou falha de outbox e comprovou rollback de agregado/auditoria. Eventos created/published/updated/cancelled/archived carregam apenas ID/versão/estado/audiência e foram comparados ao schema específico/ordem de versões. Sem evento extra em no-op/replay/erro. Relay/consumidores/Rabbit publish permanecem futuros.

Sem histórico de localização do usuário, origem de busca persistida, telefone, dados de provedor ou segredos nas respostas/eventos/logs. Ticket não é buscado pelo servidor nem prova compra/participação. [Inventário](../privacy/data-governance.md) identifica snapshot idempotente como dado restrito, audiência física, arquivos temporários/EXIF, destinatários/retensão/direitos e responsabilidades. Reencodificação não equivale a moderação de conteúdo.

## 8. Verificações efetivamente executadas

| Check | Resultado observado |
| --- | --- |
| `make backend-check` final | fmt, vet e testes Go passaram; testes específicos de normalização/IANA/DST/meia-noite/fases/tickets/imagens/configuração |
| `make contracts` final | OpenAPI1.1.0 válido (31 operações), envelopes events/realtime e payload Experiencev1 compilados |
| sqlc1.31.1 repetível | snapshot SHA256 antes/depois: **7 arquivos, zero diferenças** |
| `make experiences-test` final | **5 grupos passaram, 6,101s**, HTTP real/pgx/PostGIS/S3 real, banco exclusivo flow_experiences_test |
| Lifecycle/autorização | drafts/PUT/publicação/correção limitada/cancelamento/arquivo, transições inválidas, ETag, creator vs outro, PRIVATE/UNLISTED, histórico redigido e WITHHELD |
| Concorrência/atomicidade | duas criações mesma chave retornaram mesmo ID/um evento; dois updates mesma versão produziram um sucesso/um conflito; hash conflitante409; rollback forçado de outbox e no-op sem evento |
| Espaço/tempo | ST_DWithin excluiu experiência distante; LIVE/ENDED e arquivamento; DST com instantes distintos e duração SQL de31d sob America/New_York; cursor por filtros/principal/limite/tampering |
| Mídia S3 real | ownership, pendente não associável, limites MIME/tamanho/chave, confirmação/repetição, arquivo inválido, expiração, bucket privado, staging replay sem alterar READY, cleanup órfão e binding preservado, constraint READY sem metadata negada |
| `make identity-test` | **9 grupos/10 subcenários passaram, 10,854s**, PG real e Redis comprovadamente parado/restaurado; upstreams de fixture, sem login externo. Bridge Flutter tem1 skip explícito, não executado neste PR |
| Imagem/Compose/smoke final | API/dependências saudáveis; down/up das três migrations, PostGIS, transação/inbox, readiness503 com Redis parado e recuperação passaram |
| Manutenção na imagem final | CLI real completou `media_checked=0` no banco principal vazio; exclusão real de objetos testada separadamente no bucket de testes |
| Higiene | scripts `sh -n`, `git diff --check` e links Markdown passaram; busca limitada de padrões de chave privada/token GitHub/access key não encontrou ocorrência nos arquivos alterados |
| Não executados | Flutter/aparelhos neste PR, terceiros Identity reais, S3 de nuvem, CI remota do workspace e deploy |

O Docker Desktop inicialmente não respondia nem ao ping. Reinício normal expirou; processos travados foram encerrados/reabertos com autorização das ferramentas, sem reset ou remoção de volumes. As integrações só foram declaradas aprovadas depois de serviços reais saudáveis. Rodadas iniciais corrigiram o harness de servidor OpenAPI relativo e a semântica de visibility omitida versus vazia explícita; respostas finais estão alinhadas ao contrato. Revisão fortaleceu checks SQL contra NULL e duração dependente de DST. Nenhuma falha local final conhecida.

## 9. Documentação e administração

Criados [revisão inicial](pr-02a-initial-review.md), [ADR0009](../decisions/0009-experiences-lifecycle-media.md), [feature/lifecycle/operação](../features/experiences.md), [schema](experiences-database.md), [contrato Flutter](../features/experiences-mobile-integration.md) e este relatório. Atualizados OpenAPI/event schema, READMEs, overview/fronteiras/escopo, governança e [ADM-014–024](../admin-capabilities.md).

Registry cobre busca/lista/detalhes, hold/unpublish/restore elegível/cancelamento, categorias, restrições, abuso, revisão de mídia, auditoria e métricas/manutenção, com permissões/auditoria/API/UI/efeitos futuros. Nenhuma UI/API ou conta administrativa implementada.

## 10. Riscos e dependências externas

Produção ainda precisa de origem HTTPS, bucket/fornecedor/região/IAM privado, bloqueio público/ACL, secret injection, lifecycle staging (inclusive uploads tardios), criptografia/backup, agendamento/alertas e homologação no S3 escolhido. Compose/SeaweedFS prova protocolo local, não provisão produtiva. Políticas de retenção/histórico/direitos/menores/avisos e responsáveis precisam de validação; os prazos são técnicos, não obrigações legais presumidas.

IDs/provedores/marca/URLs legais e homologação física PR-01 continuam pendentes conforme proprietário, sem bloquear Experiences independente. Relay e consumidores/índices externos não existem; não prometer entrega RabbitMQ, recomendações ou RSVP. Restrição de publicação não retira conteúdo antigo automaticamente: hold de conteúdo é operação explícita futura. Administração e atendimento de direitos completos seguem em ciclos próprios.

## 11. Status

**PR-02.A concluído no escopo técnico local.** Domínio, migração, lifecycle HTTP, visibilidade, espaço/tempo, catálogo, mídia real, contratos, auditoria/outbox, testes e documentação entregues. Arquivos disponíveis para revisão no workspace, sem staging/commit/push/merge/deploy. Recursos desta stack são encerrados preservando volumes; reabrir com `make up`.

## 12. Requisitos exatos PR-02.B

Seguir [especificação de integração](../features/experiences-mobile-integration.md): cliente tipado dos schemas finais, formulário/draft/detalhes/minhas/publicar/cancelar/arquivar, catálogo real, fases/DST/IANA/UTC, privacidade da audiência, ETag/If-Match e reconciliação412; chave de criação preservada em timeout, PUT completo sem alteração de campos protegidos; integração S3 POST com fields intactos/sem bearer, confirm READY próprio, associação e capa autorizada sem cache global. Respeitar limites/erros/restrições e o coordenador Identity sem retry cego de escrita; acessibilidade e testes Flutter contra API/PG/S3 reais. Configurar endpoint S3 alcançável no emulador/aparelho e TLS de release. Não antecipar Participation, feeds, Flows viewer ou pagamentos.
