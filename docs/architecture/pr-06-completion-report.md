# Relatório de execução — PR-06

09/11/2026, America/Recife. Participação, convites, Minha Agenda e check-in implementados no repositório, preservando os ciclos anteriores. O agente não executou staging, commit, push, merge, instalação física ou deploy externo. Verificações automatizadas/local são separadas da homologação física e de produção.

## 1. Estado inicial do Git

`main`, HEAD inicial `1b7c5f7f262a0bc89c13e76e136a9d9d222f09e2`, índice vazio e 59 arquivos novos/modificados do PR-05 na árvore. Snapshot de hashes e OpenAPI anterior guardados em `/private/tmp/flow-pr06-*`, sem configs privadas. [Inspeção inicial](pr-06-initial-review.md).

Durante a implementação, HEAD avançou **externamente** para `0c6ab8d45cc2de15fa76833e94f4393d6a4620b4` (“implementa PR-05”). Esse commit incluiu também os arquivos iniciais de migration 00007, queries Participation e revisão PR-06 que já estavam na árvore naquele momento. O agente não realizou esse commit nem o desfez. Migration00007 foi mantida igual ao commit; complementos operacionais estão na 00008, compatíveis com banco que já tenha aplicado 00007. Não houve exclusão de arquivos anteriores nem alteração de token Mapbox, assinatura pessoal, conta temporária ou SDK fixado.

## 2. Arquivos alterados

| Área | Arquivos do PR-06 |
| --- | --- |
| Módulo Go | `backend/internal/participation/{model,service,members,invitations,checkin,lists,http}.go`, `config_test.go` |
| Experiences | Novo `capacity.go`; `service.go` compartilha autorização e manutenção; Home/Radar/Explore/Flows/list e queries recebem filtro de bloqueio por principal |
| Banco | Migrations00007/00008, `backend/queries/participation.sql`, alterações mínimas em experiences/home/radar/explore_flows.sql; sqlc `participation.sql.go`, models/querier e gerados correspondentes |
| API/contratos | `backend/cmd/api/main.go`, `cmd/contractcheck/main.go`, `contracts/openapi/flow.yaml`, `events/participation-payload.schema.json`, README de contratos |
| Flutter | Novos `features/participation/{participation_repository,participation_store,participation_panel,agenda_page,participation_management_page,checkin_page}.dart`; router, detalhe/controller e atalho na Home |
| Testes | Go `integration/participation_test.go`/`participation_flutter_test.go`, harness/boundary em experiences_test; Flutter `participation_test.dart`/`participation_contract_test.dart` e ajuste de rolagem no teste existente da Home |
| Operação | `.env.example`, Compose, Makefile com alvos participation-test/participation-mobile-contract, smoke para oito migrations somente em banco vazio |
| Documentação | Revisão/este relatório, ADR0011, guia Participation, READMEs, índice de features, inventário de dados e ADM-039–044 |

Nenhuma dependência Flutter/Go adicional, permissão de câmera/GPS, backend auxiliar, microsserviço ou fixture na aplicação. Configurações privadas/artefatos/logs ficam ignorados pelo Git. Parte dos arquivos anteriores do PR-05 aparece integrada no commit externo; alterações PR-06 permanecem revisáveis na árvore atual.

## 3. Modelo e migrações

Experiences continua agregado de experiência, com capacidade/agenda/lifecycle existentes. Participation é um módulo no mesmo processo/banco, referenciando IDs existentes. `interested` é independente de estado: NONE/PENDING/CONFIRMED/DECLINED/CANCELLED/REMOVED. NONE+interesse corresponde à intenção conceitual INTERESTED, sem reservar vaga. Check-in é registro separado e versionado, não status irreversível da participação.

Uma relação por pessoa/Experience, um convite atual por destinatário/Experience e um registro de presença. Auditoria, recibos idempotentes24h e outbox transacionais. Migration00007 cria o subdomínio/políticas/triggers;00008 acrescenta índices de manutenção e eliminação de credencial efêmera ao excluir a sessão. Rollback/up real testado sem perder registro Identity/Experience anterior à fronteira Participation. [Máquina de estados/decisões](../decisions/0011-participation-capacity-checkin.md).

## 4. Endpoints e contratos

OpenAPI **1.5.0, 65 operações: 23 novas**. Paths/schemas dos 42 endpoints anteriores preservados estruturalmente contra o snapshot anterior ao PR-06; novo payload de eventos compilado pelo verificador existente.

- GET `/v1/experiences/{id}/participation`; GET/PUT `.../participation-settings` com ETag composto.
- PUT/DELETE `.../interest`.
- POST `.../participation/confirm`, `/request`, `/cancel`.
- GET `.../participants`; POST `.../participants/{userId}/approve`, `/decline`, `/remove`, `/block`, `/unblock`.
- GET/POST `.../invitations`; POST `/v1/invitations/{id}/accept`, `/decline`, `/revoke`.
- GET `/v1/me/agenda`.
- POST `.../check-in-credential`, `.../check-ins/validate`, `.../check-ins/{userId}/revoke`.

Autenticação/ownership/erros padronizados, no-store, limite20/50, cursor HMAC por conta/recurso/seção/filtros, TTL15min. JSON estrito, limites de corpo/query, chaves UUID, operações explícitas. Retry de mutação com mesma chave retorna recibo original24h; cliente reconcilia estado atual e não reproduz POST automaticamente. Emissão de credencial é rotativa/sem recibo. [Semântica completa](../features/participation.md#operações-http).

## 5. Capacidade

Somente CONFIRMED ocupa vaga. Identity→linha Experience é a ordem de lock para todas as escritas, incluindo confirmação, aprovação, convite aceito, cancelamento e edição de capacidade. Triggers PostgreSQL também impedem overbooking e redução abaixo do confirmado, inclusive por escritor que omita a política Go. Não há contador Redis, waitlist ou reserva por interesse/solicitação/convite pendente.

Lotação409 preserva PENDING/convite. Cancelar/remover libera a vaga; repetição não duplica eventos. Capacidade null é ilimitada; redução abaixo das confirmações409, sem expulsão automática. Configuração obsoleta412. Alterar capacidade atualiza versão/auditoria/outbox da Experience; o editor geral continua protegendo atributos publicados. Organizador é o criador e não ocupa assento. Conta restrita não libera assento silenciosamente: remoção/cancelamento precisa ser explícito/auditado.

## 6. Convites e aprovações

PUBLIC/UNLISTED: FREE confirma diretamente, APPROVAL solicita e aguarda criador, INVITE aceita convite. PRIVATE exige convite individual válido, inclusive após mudança de audiência de um rascunho. Não há descoberta por UUID/link. Convite pendente válido ou confirmação concede leitura privada autenticada; bloqueio, conta indisponível/moderação retiram acesso conforme política atual.

Criador convida conta existente por UUID conhecido ou handle exato, sem contatos/telefone/busca de perfis. Inelegíveis têm erro uniforme e limites de abuso; default72h/1..168h, limitado ao fim. Pendência duplicada não cria outra; novo convite após terminal/expirado recebe novo ID. Somente destinatário aceita/recusa; revogação PENDING pelo criador. Aceito exige remover participação para retirar o acesso. Rejeitar/remover/bloquear revoga convites anteriores; desbloquear não reconfirma nem restaura convite. DECLINED/REMOVED dependem de novo convite explícito para reentrada.

## 7. Agenda e check-in

Minha Agenda consulta relações e agregado atual, com próximas confirmadas/interesses/solicitações/convites/histórico, ordenação UTC/início/id e fuso IANA. Cancelamentos/remoções/alterações refletem na leitura seguinte. Acesso privado perdido mantém somente referência pessoal indisponível, sem título/local/horário protegidos. Criador usa Minhas experiências para suas organizações, sem participação fictícia. Nenhum calendário externo.

Check-in: participante CONFIRMED emite código aleatório base32/80bits/16 caracteres, default120s e janela30min antes até fim. Organizador autenticado confere pessoa e digita o código na própria Experience; resposta usa perfil público mínimo. HMAC/sessão/validade/janela/estado/bloqueio/conta/lifecycle autoritativos; uso único e registro único. Mesmo comando retorna recibo; novo comando com código consumido409. Rotacionar/revogar/cancelar/remover invalida credencial; presença tem revogação/histórico próprio e pode ser registrada novamente com nova verificação elegível, incrementando versão.

Sem câmera/GPS. Código isolado não concede participação nem acesso privado, não comprova localização física automaticamente e não valida bilheteria externa. Aviso sobre pagamento/ingresso na UI quando aplicável. Não há código bruto em audit/outbox/recibo/logs; memória transitória é limpa em background/conta/saída/expiração.

## 8. Integração Flutter

Detalhe existente recebe situação e ações autorizadas, interesse/confirmar/solicitar/cancelar/convite/check-in. Gestão contextual do criador tem modalidade/capacidade/pendências/confirmados/convites/aprovar/recusar/remover/bloquear/desbloquear/revogar presença. Home recebe acesso à Minha Agenda. Rotas protegidas `/agenda`, `/experiences/:id/participants` e `/experiences/:id/check-in`; sem formulário de evento duplicado.

Mesmo Dio/Identity/Riverpod/go_router/design system. Stores por rota cancelam/descartam respostas antigas, deduplicam páginas, conservam chave após timeout até reconciliação, descontam tempo de transporte da validade recebida e não confirmam otimisticamente. Detalhe privado de convidado é descartado em background/saída/até60s; mudanças próprias revalidam o detalhe. Tema claro/escuro, texto ampliado, listas compactas, feedback/contexto de conflito e acessibilidade básica testados.

## 9. Segurança e privacidade

Autorização por objeto no Go, sessão/conta/onboarding atuais nas escritas, ownership/estado/audiência na transação. Lista nominal só para criador, nenhum telefone/identidade federada. Bloqueio contextual exclui detalhes/capa e Home/Radar/Explorar/Flows/mídia, inclusive URL emitida anteriormente. Sem novo Social Graph, GPS, câmera, analytics oculto ou notificação push.

Quota persistida conta tentativas recusadas; origem Identity continua limitada. Auditoria180 dias, recibos24h, códigos expirados+1 dia, quotas2 dias, manutenção em lotes500; sessões excluídas eliminam credenciais. Histórico de relações/convites/presença permanece para finalidade do agregado/conta, sem política de expurgo inventada. Produção exige decisão de retenção/eliminação/contestação e agenda operacional. [Inventário](../privacy/data-governance.md) e [ADR0011](../decisions/0011-participation-capacity-checkin.md).

## 10. Testes realmente executados

| Verificação | Evidência observada |
| --- | --- |
| Go | gofmt, vet e testes direcionados de Participation/Experiences/API/contractcheck aprovados; configurações/limites/chave de domínio cobertos |
| SQL/contratos | sqlc gerado; OpenAPI e schemas de eventos válidos; comparação estrutural dos contratos antigos; rollback/up00007/00008 preservando Identity/Experience/Flows no banco de teste |
| PostgreSQL/S3 real | Oito testes aprovados,11,012s: quatro novos Participation e regressões lifecycle/Home/Radar/Flows; última vaga/dupla aprovação, idempotência/cancelamento, redução/trigger, convite privado/duplicado/expirado/revogado, conta/bloqueio, mídia anterior bloqueada, check-in/rotação/expiração/replay/sessão, remoção/cancelamento e agenda/audit/outbox/rollback. O teste de privacidade passou novamente após a correção de alvo sem participação (404, sem linha/resposta fictícia),3,560s |
| Flutter/Dio ↔ Go/OpenAPI/PostgreSQL | TestFlutterParticipationContract aprovado,24,724s/um caso Flutter; convite privado, acesso, aceite/capacidade, agenda, código/presença/replay, remoção/redaction, modalidade APPROVAL/configuração ETag e liberação de vaga, usando repositório real |
| Flutter | 39 testes únicos pertinentes aprovados entre rodada direcionada e revalidação Home: oito novos e regressões de detalhes/controllers/Home/Flows/autenticação/navegação. A rodada agrupada teve 38 aprovados e um teste antigo da Home precisava tornar o título visível antes do toque; após ajuste, os cinco testes Home passaram. Sem alteração do comportamento de navegação para satisfazer o teste |
| Análise estática Flutter | Sem issues na rodada final,8,1s |
| Stack local/builds | `make mobile-local` e atualização da imagem final aprovados; migração8, API/worker saudáveis, healthz200/readyz200, rotas novas anônimas401 e rota de fixture404. Contagens de contas/experiências/capas/Flows preservadas. Android APK debug aprovado138,9s; iOS debug para simulador aprovado38,9s. Artefato iOS sem câmera/microfone/contatos ou ATS global; dependências/configuração nativa iguais ao PR-05 |

Testes transacionais somente em `flow_experiences_test`/bucket `flow-experiences-test`, nunca banco principal. Nenhum smoke destrutivo no principal, instalação física, câmera/QR, benchmark de carga ou execução nativa de PR-06 alegados. Logs temporários em `/private/tmp/flow-pr06-*`, não versionados. O teste nativo de vídeo do PR-05 não foi repetido: este ciclo não altera player/dependências nativas.

## 11. Pendências externas

Homologação física Android/iPhone com duas contas reais/autorizadas: rede ambígua, agenda, convites privados/revogação, conferência presencial, expiração/rotação/replay, background/troca de sessão, leitor de tela e fluidez/memória. [Roteiro](../features/participation.md#validação-e-roteiro-físico). Não há gate de câmera neste protocolo.

Credenciais/distribuição/IDs/assinatura de produção, SMS/Google/Apple, HTTPS/deep links, marca/URLs legais e revisão de privacidade/menores/retenção permanecem externos dos ciclos anteriores. Um único acesso temporário de desenvolvimento foi preservado; não foram criadas outras contas fictícias para contornar configuração de autenticação. Runtime físico Mapbox anterior não foi homologado neste PR. Nenhuma integração de bilheteria/calendário/push foi simulada.

## 12. Capacidades administrativas

[ADM-039–044](../admin-capabilities.md): inspeção/histórico de aprovação, revogação/restrições/remoções, convites abusivos, contestação de presença, capacidade/conflitos/reparação consistente e operação/retenção/futuras notificações. Cada uma identifica permissões futuras, escopo/caso/auditoria, efeitos e UI/contratos necessários. Sem plataforma/role/API administrativa; operadores não devem editar estados/contadores ou desativar triggers.

## 13. Status técnico

**PR-06 tecnicamente concluído no ambiente local.** Domínio, transações, mídia autorizada, integração Flutter/Go real, UI, análise estática, stack local e builds Android/iOS aprovados. Homologação física e configuração de produção permanecem externas conforme seção11. Branch `main`, HEAD observado `0c6ab8d45cc2de15fa76833e94f4393d6a4620b4`, índice vazio; alterações finais disponíveis para revisão. Nenhum commit/staging/push/merge/deploy externo pelo agente. Para atualizar o app, a partir de `apps/mobile`, com Mac/iPhone na mesma rede e stack ligada:

```sh
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

## 14. Preparação para PR-07 — Social

IDs/versões/estados/outbox e revogação contextual estão disponíveis para contratos futuros. CONFIRMED é somente sinal de elegibilidade, não autorização automática para Event Space/publicação/chat/mídia: futuro backend deve revalidar conta/bloqueios/audiência/lifecycle/moderação e retirar permissões após remoção/cancelamento. Consumidores deduplicam eventos e reconsultam autorização antes de expor/notificar dados privados. Nenhum Social Graph, publicação, chat, comunidade, Event Space, P2P ou módulo PR-07 foi iniciado.
