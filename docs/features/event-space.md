# Event Space — contratos e operação PR-08

Cada experiência usa seu UUID como identidade estável do espaço. Entrada real nos detalhes → Event Space. Abas Mural, Mídia, Participantes; responsáveis também veem Denúncias e Conteúdo oculto. Sem aba Chat fictícia. Flutter usa Material3/design system, mesmos cards, compositor, autor e player Social.

## Matriz autoritativa

Todas as linhas exigem sessão atual, onboarding, conta ativa, ausência de restrição Social global e bloqueios incompatíveis com o organizador. WITHHELD na Experience, suspensão da plataforma ou restrição de publicação do organizador retiram o conteúdo. Check-in não é requisito.

| Estado/ator | Resumo | Conteúdo/galeria/lista | Publicar/editar/curtir/comentar | Moderação local |
| --- | --- | --- | --- | --- |
| DRAFT, organizador | configuração própria | não | não | não |
| DRAFT, demais | 404 | 404 | 404 | 404 |
| PUBLIC/UNLISTED, não membro/interessado/PENDING | prévia já pública | 404 | 404 | 404 |
| PRIVATE, convite pendente ou não membro | 404 | 404 | 404 | 404 |
| PUBLISHED futura/LIVE, CONFIRMED elegível | sim | sim | sim | somente papel explícito |
| PUBLISHED futura/LIVE, organizador | sim | sim | sim | sim; gerencia papéis/pausa/Participation |
| ENDED/CANCELLED/ARCHIVED, organizador/CONFIRMED | sim | sim, histórico | 409 somente leitura | sim |
| Pausa local ou restrição de interação | sim | sim | 409 | restrição revoga papel do participante |
| Removido/cancelou/bloqueado | prévia PUBLIC/UNLISTED se elegível; PRIVATE404 | 404 | 404 | 404 |
| Conta suspensa/restrita, organizador bloqueado ou espaço globalmente suspenso | erro de sessão/404 conforme fronteira | não | não | não |

Acesso histórico não concede participação. Cancelamento/arquivamento não reabrem o espaço. Dono pode remover/bloquear/desbloquear membros no histórico pelo contrato Participation existente. Aprovar/recusar/inscrever continuam sujeitos à janela original. Um post também exige autor atualmente elegível; comentários/contagens filtram autores removidos ou bloqueados. Retorno elegível pode reexibir conteúdo histórico; papel de moderador exige nova nomeação. Local RESTRICT persiste até ALLOW.

Prévia omite contagem nominal, roster, mídia e posts. UNLISTED é acesso direto sujeito à ACL de Experiences; consentir descoberta Flows não concede Event Space. Participantes autorizados recebem apenas user_id/display_name/handle/role; número de confirmados exclui organizador, listado separadamente como responsável. Sem telefone, fornecedor, check-in ou localização individual.

## API e paginação

OpenAPI1.7.0 contém sete novas operações, todas autenticadas e no-store:

- GET `/v1/experiences/{experienceId}/space`: resumo, lifecycle/fase e capabilities calculadas.
- GET `/space/feed`, `/space/gallery`, `/space/participants`: conteúdo contextual.
- GET `/space/reports`, `/space/hidden`: metadados mínimos para moderadores.
- POST `/space/moderation`: target_type/target_id/action/reason, Idempotency-Key.

Caminhos `/space/...` são relativos ao mesmo prefixo da experiência. Cursor HMAC15min vincula seção, experiência, usuário/sessão, snapshot e limite (default20/max50), ordem created_at/UUID decrescente. Cursor de outra seção/conta é inválido. Posts novos entram na atualização manual. Não existe recomendação/fan-out. SQL consulta documentos/agregações em lote, sem consulta de autor/mídia por item na aplicação.

Criação usa POST `/v1/social/posts` com `context: EVENT_SPACE`, `visibility: SPACE`, `experience_id`, body e media_ids. Detalhe, PATCH, DELETE, likes, comentários, reports, uploads e streaming são as operações Social existentes. Não há endpoint duplicado de publicação ou mídia. EVENT_SPACE não aparece nos feeds/perfis Social; referências a Experience e mídia não geram link público externo permanente.

Capabilities: can_read, can_write, can_moderate, can_manage_roles, can_manage_participation. Não são credenciais: toda ação revalida no servidor. Erros404 ocultam existência protegida;409 space_read_only sinaliza leitura histórica/restrição;400 payload/cursor inválido;401/403 mantêm políticas Identity;429 quotas existentes. Recibos24h não contornam revogação de escrita.

## Moderação

Motivos categóricos ABUSE/SPAM/PRIVACY/SAFETY/OTHER. Confirmação com motivo no Flutter. POST/COMMENT HIDE/RESTORE altera local_hidden, separado da moderação global. MODERATOR GRANT/REVOKE só organizador, alvo CONFIRMED e elegível para nomeação. PARTICIPANT RESTRICT/ALLOW não dá poder sobre contas; moderador não restringe outro moderador, nem organizador/si próprio. SPACE PAUSE/RESUME só organizador e não reabre lifecycle. REPORT REVIEW registra revisão local sem resolver relatório global. Denúncias mostram tipo/ID/motivo/data/revisada, sem denunciante/body. Conteúdo oculto retorna só metadados de alvo, sem texto.

Remoção integra POST Participation `/participants/{userId}/remove` (e block/unblock existentes), optional reason categórico compatível com clientes `{}` anteriores. Audit inclui motivo. O trigger transacional revoga papéis quando perde CONFIRMED/é bloqueado, emite eventspace.moderator.revoked. Outras ações emitem eventspace.moderation.{ação}; operações Social mantêm seus eventos existentes. Envelope/payload mínimo versionado em contracts/events, sem texto.

CLI existente `social-moderation`: `space`, `hide-space`, `show-space`, além de contenção Social. Exige SOCIAL_MODERATION_DATABASE_URL separado, operator e case atribuíveis. `space` inspeciona a Experience associada, não exporta posts/roster; suspensão global impede leitura, enquanto pausa local impede escrita. Restauração não ignora lifecycle/participação/ocultação. Não há HTTP admin nem painel geral.

## Mídia, cache e retenção

Mesmos assets SOCIAL, S3 privado, worker Go, variantes sanitizadas e FFmpeg/FFprobe≤15s, sem cópia para a galeria. Imagem≤5MiB, vídeo≤32MiB, até4 assets/post. Cada item da galeria referencia asset/post original e abre o detalhe; reprodução só ao toque, sem autoplay, player descartado ao navegar/background/trocar aba/conta. Sem WebRTC/P2P.

Capacidades30s revalidam sessão, ACL, moderação e participação a cada GET/range. Mídia vinculada não usa autorização de preview para contornar o post. Stores isolam conta+rota/experiência, cancelam resposta antiga e removem documentos no background/saída/sessão e TTL absoluto30s; paginar não prolonga autorização anterior. Sem push/polling: revogação remota retira imediatamente novas leituras do servidor e a UI já carregada expira em até30s ou na próxima revalidação. Não é possível apagar cópias já baixadas por dispositivos externos.

Direitos de exclusão: autor pode apagar seu post contextual conhecido mesmo depois de removido, e o próprio comentário conhecido sem ler o pai; autenticação/conta e contenção global continuam aplicáveis. Deleção apaga texto no comando; mídia segue limpeza compartilhada: objetos/órfãos com idade24h e tombstones7dias; recibos24h, quotas2dias, audit e reports180dias. report_reviews é removido junto à denúncia. Lifecycle não apaga conteúdo nem define retenção indefinida. Configuração/papéis/restrições são relações persistentes enquanto existir a Experience, sem nova limpeza automática não aprovada. Produção exige prazo de conteúdo ativo, política de direitos/contestações/backups/base legal/menores e processo de eliminação dos agregados, auditável e separado de arquivamento.

## Operação, validação e PR-09

`make event-space-test` usa somente DB flow_experiences_test e bucket flow-experiences-test (reset explícito de fixtures). `make event-space-mobile-contract` exercita Dart/Dio contra API Go/OpenAPI/PG reais; fixtures de sessão existem só no binário de testes. Não rodar smoke/rollback no banco principal com dados. Usar Flutter pelo wrapper fixado `flutterw`, preservar device.local.json e tokens fora do Git. Nenhuma configuração externa nova é necessária ao contexto.

Diagnosticar: sessão → Experience/conta/moderação → Participation/blocks → papel/restrição/pausa → post/local/global/deleção → asset/processamento → capability/expiração → S3. Logs categóricos/request_id sem body, tokens, telefone, URL ou UUIDs desnecessários. Probes/latência e idade de fila existentes; métricas/painéis específicos/carga real são pendências operacionais, não homologação.

PR-09 deverá reutilizar UUID/ACL/lock e revogação; consumir eventos com event_id deduplicado, verificar estado atual antes de entregar mensagens ou notificar, revalidar sessões de conexões ativas e limitar presença efêmera. Não transportar participantes/copiar autorização para claims permanentes. Este PR não entrega mensagens, WebSocket de chat, presença, DM ou push.

## Extensão PR-09 — Chat

A aba Chat foi implementada com histórico, WebSocket, reconciliação e moderação próprios, reutilizando a autorização acima. Mural/mídia/participantes mantêm os contratos anteriores. [Operação, limites e retenção do chat](chat.md), [ADR0014](../decisions/0014-chat-persistence-realtime.md). Não confundir remoção definitiva de mensagem com ocultação/restauração de post.
