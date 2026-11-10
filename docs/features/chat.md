# Chat e Realtime — PR-09

## Entrada e política

Detalhes da Experience → Event Space → Chat. Mural, Mídia e Participantes existentes preservados. Somente organizador e CONFIRMED atualmente elegíveis leem histórico; interessados/PENDING/convites pendentes e visitantes PUBLIC/UNLISTED recebem404. PRIVATE não é revelada por ID. Moderador precisa nomeação e participação atuais. Check-in não é requisito.

Mesma matriz SQL Event Space: DRAFT indisponível; PUBLISHED futura/LIVE permite enviar; ENDED/CANCELLED/ARCHIVED permite apenas histórico autorizado. Pausa e restrição local impedem escrita; WITHHELD/suspensão global, conta restrita, bloqueio incompatível ou remoção revogam leitura. Arquivar/cancelar não reabre chat. Exclusão própria conhecida permanece possível após remoção, desde que sessão/conta sejam elegíveis; moderador só remove dentro do próprio espaço. Histórico não concede nova autorização.

## Transporte e contratos

OpenAPI1.8.0 acrescenta4 operações (103 totais):

- GET `/v1/experiences/{experienceId}/space/chat`: capacidades, cursor atual e limite de texto.
- GET `/chat/messages`: histórico por `cursor` ou recuperação por `after`, mutuamente exclusivos; default20/max50. Caminho relativo ao prefixo `/space` da mesma experiência.
- DELETE `/chat/messages/{messageId}`: body `{reason}`, exclusão idempotente. SELF para autor; ABUSE/SPAM/PRIVACY/SAFETY/OTHER para remoção contextual autorizada.
- GET `/chat/socket`: upgrade WebSocket, Authorization bearer em cabeçalho, subprotocolo flow.chat.v1, sem query. Sem envio REST duplicado.

Schemas em contracts/realtime/chat.schema.json e envelope.schema.json. Toda frame contém message_id UUID, type, version1, sent_at UTC e payload; correlation_id opcional identifica a frame de envio respondida. Experiência é vinculada à conexão/URL e ao cursor; autor vem da sessão. Campos de autoria/papel/experiência arbitrários não são aceitos no payload de envio. A sequência é string decimal.

| Cliente → servidor | Payload | Resposta |
| --- | --- | --- |
| chat.join | cursor de recuperação do histórico HTTP | chat.joined; alterações persistidas seguintes e chat.sync |
| chat.message.send | client_message_id UUID estável e body | chat.message.ack após commit, ou chat.error com código/ID do cliente |
| chat.leave | objeto vazio | encerra conexão |
| chat.ping | objeto vazio | chat.pong; sem evento durável |

Servidor entrega chat.message.created/chat.message.removed (documento atual), chat.sync (cursor confirmado/capabilities), chat.reset (mudança de política), chat.access.revoked (sem UGC, código categórico). Fechamento sem evento terminal também exige revalidação/reconexão. Removida tem body/author nulos; não conservar texto anterior. Mensagem confirmada no ACK não é confirmação de leitura nem garantia de presença física.

Cursor HMAC15min vincula modo, espaço, usuário, sessão, posição, snapshot e versão de política. Histórico ordena created sequence desc; recuperação ordena change sequence asc, incluindo tombstones. next_cursor indica páginas restantes; resume_cursor confirma posição de recuperação. Mudança de política retorna reset em vez de confiar no cache anterior. Cursor expirado/inválido deve ser descartado e o snapshot recarregado. Nenhum cursor é credencial para acesso.

Compatibilidade: versão/subprotocolo1; clientes ignoram eventos desconhecidos e usam estado seguro para erros desconhecidos. Servidor rejeita versões não suportadas. Mudança incompatível futura exige protocolo novo e política de adoção, sem reinterpretar payload1.

## Persistência e distribuição

Migração11: rooms (contador por Experience), messages (UUID/autor/client ID/hash/body/created sequence/UTC/deleção/moderação), changes (ordem de alterações), connections (leases) e policy_clock (invalidação sem PII). Sem agregado/membro duplicado. Send: Identity/sessão → Experience → contador/mensagem → audit/outbox, mesmo commit. Concorrência não depende de timestamps nem gera ACK antes do PostgreSQL. Reenvio igual usa o mesmo registro; outro texto com mesmo UUID retorna idempotency_conflict. Não editar mensagens neste ciclo; enviar novo texto exige novo client ID.

Cada instância consulta alterações persistidas em lotes limitados para suas conexões. ACL é atual na query e antes da escrita no socket. Leituras e recuperações sensíveis são auditadas; heartbeats não geram outbox/auditoria comportamental. Novos fatos chat.message.created/removed usam contracts/events/chat-payload.schema.json (IDs/sequência), sem body. Denúncia usa o fato Social existente; não cria uma segunda tabela ou pipeline. CLI global mantém fatos auditáveis operacionais e registra alterações no mesmo change log.

A revogação funciona entre instâncias: todas leem Identity/ACL/clock/leases no mesmo PostgreSQL. Padrão de detecção ociosa1s; pode somar agendamento, consulta≤3s e escrita≤2s/fechamento. Não é SLA nem instantaneidade. Antes de cada nova entrega há revalidação; uma escrita já em trânsito ou bytes obtidos externamente não podem ser recolhidos. Caso não seja possível entregar evento terminal, o cliente fecha por erro/watchdog e revalida por HTTP. Indisponibilidade do banco interrompe entrega, sem servir histórico protegido stale.

## Reconexão e interface

Controller central por conta/experiência. Auth/refresh e transporte são dependências testáveis, fora do widget. O conector nativo usa Authorization e WSS em origem HTTPS; não suporta browser neste ciclo. Nenhum token vai à URL, log ou storage do chat.

Backoff exponencial1–30s+jitter0–499ms, até8 tentativas consecutivas sem sync; depois, reconexão manual. HTTP autenticado recupera snapshot e alterações posteriores ao cursor anterior, no máximo10 páginas/500 alterações por tentativa; se exceder, há aviso para consultar histórico. IDs autoritativos deduplicam ACK/eventos; change_sequence impede que entrega antiga restaure uma mensagem removida. Reenvios ambíguos preservam client_message_id; falhas definitivas exigem ação do usuário. Envio sem ACK/evento após20s fica sem confirmação, com texto/ID preservados. Não alegar que uma mensagem não foi persistida apenas por falta de ACK.

Memória de até500 mensagens por janela e20 pendentes. Paginar para trás descarta as mais novas da janela e oferece retorno às recentes; não limita o histórico persistido a500. Composer/rascunho próprio somente em RAM; background encerra socket, remove histórico e preserva pendência própria para reconciliar na retomada. Logout/troca de conta/revogação apagam conteúdo e pendências. Watchdog fecha conexão sem frame válida por6s. Não há socket artificialmente ativo no background, fila em disco ou timer agressivo de reconexão.

Ponto transitório “Chat •” aparece só após primeira abertura da sessão e mensagem nova em outra aba; sem contagem de não lidas/global ou recibo de leitura inventados. Presença/last seen não implementados, por decisão explícita. Presença de conexão não seria presença física.

## Limites e backpressure

| Configuração | Padrão / limites |
| --- | --- |
| CHAT_BODY_LIMIT |2000 caracteres Unicode, até3000 |
| CHAT_SEND_MINUTE |30 tentativas/min por conta, até120; compartilha contador de mutação Social |
| CHAT_USER_CONNECTIONS |3 por conta entre sessões/instâncias, máximo10 |
| CHAT_ROOM_CONNECTIONS |200, máximo2000; contador conservador inclui conexões da conta em outras salas |
| CHAT_PROCESS_CONNECTIONS |1000, máximo5000, por processo |
| CHAT_PAYLOAD_LIMIT |16384 bytes, configurável4096–65536 |
| CHAT_QUEUE_LIMIT |16 frames de entrada, máximo64; overflow encerra conexão |
| CHAT_POLL_MS |1000ms,250–2000; consulta interna do servidor, sem polling HTTP Flutter |
| CHAT_MAX_CONNECTION_SECONDS |600s,30–600; reconectar com sessão atual |
| CHAT_ALLOWED_ORIGINS |vazio: apenas cliente nativo sem Origin; se presente, lista exata de origens HTTPS aprovadas |

Valores padrão também estão em .env.example e são repassados ao flow-api pelo Compose. Nenhum segredo ou origem nova foi provisionado.

120 frames/min por socket; lotes de até50; escrita serial com timeout2s e sem fila de broadcast ilimitada. Consumidor lento deixa de avançar cursor e é desconectado se escrita exceder prazo; histórico permite recuperar. Leases compartilhadas expiram15s após falha de processo e são renovadas a cada5s. Admission usa advisory locks por conta/sala. Graceful shutdown cancela e fecha sockets antes de encerrar HTTP; requests websocket não dependem do deadline HTTP8s.

Counters de conexões ativas/aceitas/erros de leitura e escrita no handler e logs agregados de abertura/fechamento, sem nomes, corpos, tokens, URL ou presença histórica. Não existe dashboard de telemetria/conversão. Antes de escalar, medir custo de consultas por conexão/entrega, contenção do clock conservador, CPU/memória, latência e conexões de banco. Redis/relay/coordenação mais sofisticada precisam evidência de carga; não provisionados neste ciclo.

## Moderação e operação

Próprio autor exclui body; organizador/moderador atual remove mensagem do seu espaço com motivo. Confirmações no Flutter. Reports CHAT_MESSAGE usam `/v1/social/reports`; lista/revisão Event Space mostram apenas alvo/tipo/razão/data, sem denunciante/body. Remoção local do chat é definitiva para o texto; não confundir com HIDE/RESTORE de posts. Quotas/flood aplicados no backend.

CLI existente social-moderation, com SOCIAL_MODERATION_DATABASE_URL separado e operator/case atribuíveis: chat-messages (UUID exato da experiência, máximo50), hide-message/show-message/delete-message (UUID exato da mensagem). Inspeção/ações auditadas. WITHHELD global pode ser restaurado apenas com texto retido e elegibilidade atual; delete não restaura body. Restrições de conta/Social e Event Space já existentes continuam autoridades. Sem HTTP admin, painel geral ou privilégio global no token do moderador.

## Privacidade e retenção

Texto é processado pela plataforma para persistência/entrega/moderação. **Não há criptografia ponta a ponta.** TLS/WSS protege transporte de produção; banco/backups/operação precisam controles próprios. Não há telefone, identidade federada, localização individual ou check-in no documento de mensagem.

Body ativo por90dias desde criação, também filtrado na leitura. Exclusão autorizada apaga body no comando; worker compartilhado elimina body expirado em lotes500/min. Metadados de mensagem/idempotência/changes até180dias desde a alteração pertinente; limpeza incremental de changes e registros sem referência pode exigir passagens subsequentes. Contador da sala permanece sem UGC para manter ordem. Não prometer idempotência após expurgo do registro; retries automáticos só existem na sessão corrente.

Reports/audit180dias, quota Social2dias; leases expiradas removidas pelo worker, sem histórico de conexões para analytics. Outbox segue governança de eventos pendentes existente, sem TTL novo que descarte fatos não entregues. Body não vai ao broker ou logs. Backup, base legal, contestação, direitos e eliminação de conta/Experience exigem processo aprovado antes de produção; tombstone/arquivamento não equivalem a apagamento completo. Bytes já recebidos externamente não podem ser apagados remotamente.

## Validação e homologação

`make chat-test`: PostgreSQL/PostGIS real no DB flow_experiences_test e bucket de testes. `make chat-mobile-contract`: Dart/Dio + WebSocket nativo contra API Go/OpenAPI e banco real, fixtures só no binário de teste. Não executar smoke/rollback no banco principal com dados. SDK via flutterw.

Homologar com duas contas/aparelhos físicos: Wi-Fi↔móvel, timeout após persistir/antes do ACK, background longo, token expirado, logout remoto, remoção com sockets em duas instâncias, rede lenta, textos longos/emoji, VoiceOver/TalkBack,320px/texto200%, memória/bateria e suspensão/cancelamento durante envio. Builds de Android e iOS simulador não são homologação física.

Produção depende ainda de domínio/TLS/WSS/reverse proxy com upgrade/timeouts adequados, IDs/assinaturas/distribuição, provedores Identity e governança/operação. Não há deploy externo nem atualização automática de app físico neste PR.

## Ativação local posterior

O PR09 não atualiza a API nem a migração do banco principal automaticamente. Quando a atualização for autorizada, `make mobile-local` prepara a rede atual, preserva as configurações privadas existentes e reconstrói API/worker/migrate. Depois, atualizar o aparelho com flutterw e config/device.local.json. O endereço LAN gravado anteriormente pode não estar disponível após troca de rede; não reutilizar um binding antigo sem preparar o ambiente. Builds e testes isolados não comprovam esse runtime físico.
