# Social — PR-07

Go/PostgreSQL/sqlc/OpenAPI1.6.0 e Flutter com sessão Identity. Acesso pelo botão Social na Home e rota protegida `/social`. Seguindo/Descobrir por recência, perfil público, detalhe/comentários, criação/edição/exclusão, grafo/bloqueios/denúncias reais. Não há dados de produção simulados, ranking, push, DM, stories, Event Space ou P2P.

## Políticas de acesso

[ADR0012](../decisions/0012-social-publication-graph-media.md). PUBLIC circula entre usuários autenticados elegíveis; FOLLOWERS somente seguidores atuais e autor. Perfil reutiliza display_name/handle/user_id Identity; sem telefone/provedor, avatar fictício ou bio não suportada. Contagens dependem do observador e só incluem conteúdo autorizado. Feed Seguindo não inclui posts próprios sem seguir (self-follow proibido). Descobrir nunca inclui FOLLOWERS. Likes únicos, operações idempotentes, comentários de primeiro nível; exclusão pelo autor do comentário ou da publicação.

Associação Experience: somente PUBLIC/PUBLISHED/VISIBLE, criador ativo/sem restrição, autor organizador ou CONFIRMED, sem bloqueio contextual/social. O fim normal preserva relatos; cancelamento/archive/moderação/restrição/audiência/revogação retiram leitura e mídia na consulta seguinte. UNLISTED/PRIVATE e consentimento de Flows não concedem exposição Social. O seletor mostra apenas experiências elegíveis para o usuário; o servidor revalida ao publicar.

Bloquear remove follows mútuos e impede novas relações/leituras/interações. Grafo, perfil, feed, post, comentários, contagens e capability de mídia aplicam a política simétrica. Desbloquear não segue novamente; likes/comentários históricos permanecem registros e podem voltar a ser elegíveis quando o bloqueio termina. Lista de bloqueados retorna somente IDs opacos, permite desbloquear e não reabre perfis bloqueados. Denunciar pessoa após bloqueá-la continua possível pelo UUID já conhecido; outros alvos exigem acesso atual. Denúncias não são publicadas nem contadas como engajamento.

## Contrato HTTP

Ver [OpenAPI](../../contracts/openapi/flow.yaml), 27 operações novas em `/v1/social`:

| Recurso | Operações |
| --- | --- |
| Política/feed | GET `/limits`, `/feed?mode=DISCOVER\|FOLLOWING`, `/experience-options` |
| Posts | POST `/posts`; GET/PATCH/DELETE `/posts/{postId}`; GET `/profiles/{userId}/posts` |
| Likes/comentários | PUT/DELETE `/posts/{postId}/like`; GET/POST `/posts/{postId}/comments`; DELETE `/posts/{postId}/comments/{commentId}` |
| Perfis/grafo | GET `/profiles/{userId}`, `.../followers`, `.../following`; PUT/DELETE `.../follow`, `.../block`; GET `/blocks` |
| Denúncias | POST `/reports` com target_type USER/POST/COMMENT, target_id e reason ABUSE/SPAM/PRIVACY/ILLEGAL/OTHER |
| Mídia | POST `/media`; GET `/media/{mediaId}`; POST `.../confirm`; GET `/media/{mediaId}/content` para prévia somente do autor; GET `/posts/{postId}/media/{mediaId}/content?ticket=...` com Range opcional |

Bearer para todas exceto content, que usa capability autenticada na emissão. Escritas respondem200 com `{id}` mínimo; upload responde autorização S3, confirmação responde estado. Todas as escritas de domínio requerem UUID `Idempotency-Key`; confirmação Media é naturalmente idempotente, sem chave nova. Mesmo ator/chave/operação/corpo retorna recibo24h; corpo diferente409. O recibo não é o estado atual: reconciliar por GET. DELETE/PUT sem texto enviam JSON `{}`. PATCH só body e `If-Match: "versão"`, exige também chave.403 conta restrita,404 indisponível/sem acesso,412 obsoleto,422 conteúdo,428 falta ETag,429 quota+Retry-After,503 falha temporária. JSON estrito, sem duplicadas/desconhecidas/nulos indevidos, corpo32KiB/query4KiB. Sem retry automático de mutações.

Listas: cursor HMAC15min ligado a sessão/conta/seção/recurso/modo/limite; snapshot, created_at/UUID DESC; default20/max50 e lookahead1. Adições posteriores ao snapshot ficam para refresh. Exclusões/restrições/bloqueios são reavaliados nas páginas seguintes. Listas e documentos no-store, janela local até30s descontando transporte; a validade absoluta da primeira página não é renovada ao carregar páginas adicionais. Expiração cancela páginas em voo. Limpar background/conta/saída. Sem polling de feed; expiração remove e oferece atualização. Mudanças próprias reconsultam dados.

## Mídia

Pipeline compartilhado do PR-05: POST S3 privado5min com MIME/size fixados, confirmação enfileira, worker sanitiza imagens JPEG/PNG≤5MiB, FFprobe+FFmpeg reais para MP4/MOV≤32MiB e≤15s. H264/AAC/yuv420p/faststart e poster JPEG. Arquivo real inspecionado, metadados descartados, nunca confiar só em extensão/MIME. max dimensão configurável padrão1920, caps de processos/memória/tempo/lease/retries existentes mantidos. Purpose SOCIAL não pode ser anexado a Flow/Experience e mídia FLOW/capa não pode ser anexada a post Social.

Até4 mídias READY de propriedade do autor, cada asset em um único post. Status UPLOADING/PROCESSING/READY/FAILED/DELETED. Não publica mídia não verificada. Flutter permite selecionar/visualizar imagem e preparar vídeo; envio/processamento por item não trava a escrita do texto, retomada explícita, consulta de processamento até30 vezes/2s somente em foreground. Recusa do servidor não anuncia sucesso; rascunho mantém texto até descarte confirmado/saída/troca de conta. Rascunho não é persistido em disco. Prévia do vídeo após processamento usa capability somente do autor no compositor, mesmo player nativo, silencioso e sob demanda; tipo/tamanho/estado reais, sem editor/efeitos. Vínculo posterior revalida a política do post também nas URLs anteriores de prévia.

Capability30s relativa/mesma origem, vinculada a sessão/post/asset/versão/variante; cada GET/range verifica sessão atual, conta, blocks, post atual e contexto Experience. Nenhum objeto S3 público/redirecionamento GET; JWT/bearer não segue para S3. URLs não vão a logs/eventos. Bytes já entregues não podem ser recolhidos remotamente. Dados decodificados ficam na tela, são descartados em lifecycle/expiração/saída; não usar caches persistentes.

### Contrato futuro de distribuição PR-10

ID estável asset UUID; sha256 dos bytes processados; verified size; MIME real; dimensões/duração; variant `sanitized-v1`; READY/FAILED/DELETED; associação exclusiva/autor/post; versão do post e permissão revogável. Peer futuro não pode autorizar por hash/ID: precisa verificar a mesma política/capability e indisponibilidade. Fallback atual é streaming Go→S3 privado com Range. Não implementar signaling/WebRTC/cache público antes de política de revogação/quotas/dispositivos/base legal. Sem P2P neste ciclo.

## Moderação operacional

Executável `/app/social-moderation` no mesmo backend/image. **Não existe endpoint privilegiado.** Exige `SOCIAL_MODERATION_DATABASE_URL`, nunca fornecida ao API/worker, e `-operator`/`-case` atribuíveis (3..100 caracteres alfanuméricos/_.:@-). Banco/credencial/OS são a fronteira de confiança: provisionar role de operação com somente tabelas/funções necessárias, segregação, MFA/secret manager/acesso de rede e trilha externa antes de produção; não usar DSN/impersonação do usuário em tickets. Saída contém conteúdo UGC/IDs e deve permanecer no ambiente do caso, sem copiar para logs públicos.

```sh
# Credencial já injetada por gerenciador seguro, sem valor no comando/histórico.
/app/social-moderation -operator operador.aprovado -case caso-123 -action reports
/app/social-moderation -operator operador.aprovado -case caso-123 -action post -target UUID_POST
/app/social-moderation -operator operador.aprovado -case caso-123 -action hide-post -target UUID_POST
```

Ações: `reports` lista50 OPEN antigos; `post` inspeciona UUID; `posts` busca50 mais recentes por autor UUID exato; `hide-post/show-post/delete-post`, `hide-comment/show-comment`, `restrict-user/restore-user`, `resolve-report`. Cada consulta/comando gera audit e fato outbox no mesmo commit; leitura é devolvida somente após sucesso da auditoria. Operador/caso no audit, eventos sem texto. Ocultar não apaga prova imediatamente; excluir apaga texto e retira acesso, sem recuperação automática. Restrição Social não suspende Identity, não altera Participation e não concede visibilidade privada. Restauração nunca ressuscita conteúdo excluído nem dispensa elegibilidade atual. Revisão humana/triagem/contestação e prazo de resposta de abuso exigem operação, não há classificador de conteúdo. Sem painel geral.

## Configuração e manutenção

`SOCIAL_BODY_LIMIT` padrão3000 (1..5000), `SOCIAL_MEDIA_LIMIT`4 (1..4), `SOCIAL_MUTATION_MINUTE`30 (5..120), `SOCIAL_EDIT_HOURS`24 (1..168). Texto de comentário≤1000. Mudanças exigem revisão/configuração e restart, sem endpoint remoto de política. Mesmo worker de mídia executa SocialCleanup e CleanupFlows em lotes a cada minuto; quotas e mídia respeitam caps globais existentes. Monitorar falha/atraso por logs categóricos e probes; não se inventou métrica de abuso/alcance. Queues/custos/carga reais precisam medição em homologação.

Exclusão apaga body imediatamente, revoga novas interações/leituras/capabilities. Fonte staging expira5min, removida após expiração+1h; arquivos não vinculados ou de posts excluídos removidos após idade24h (até1min adicional se worker saudável). Post/comment tombstones7dias; asset tombstone7dias após limpeza e sem FK. Posts só expurgados quando mídia já DELETED; manutenção é repetível/retry em falha S3. Auditoria180dias, denúncias180dias a partir de criação (inclusive abertas: operar antes do prazo), receipts24h, quotas2dias, lotes500. Outbox segue política compartilhada, sem texto/mídia/código bruto. Contas e conteúdo ativo conservados por finalidade do produto; direitos LGPD/backups/retenção legal/menores exigem processo aprovado, não alegar conformidade jurídica automática.

## Validação e homologação

`make social-test` usa somente banco `flow_experiences_test` e bucket `flow-experiences-test`, inclui contratos em requests/responses, rollback/up e FFmpeg/S3 reais. `make social-mobile-contract` integra repositório Flutter/Dio com Go/PG/S3. Testes Flutter focados em `social_test.dart`, regressões `explore_flows_test.dart`/`participation_test.dart`, analyzer e builds. Consulte [relatório](../architecture/pr-07-completion-report.md) para resultados efetivamente executados.

Roteiro físico pendente: duas contas autorizadas; PUBLIC/FOLLOWERS/follow/unfollow; perfil/contagens/scroll/cursor; texto/media<=15s e recusa>15s; rede intermitente/timeout de publish sem duplicação; session switch/background/expiração; bloqueio/revogação em outro aparelho inclusive URL anterior; comentários/report/CLI auditados; tema claro/escuro/texto ampliado/leitor de tela; um player silencioso/memória/bateria; remoçãoS3/worker atrasado. Sem alegação de instalação ou homologação física neste PR.

Sem origem HTTPS/universal links/app links aprovada não há botão de compartilhar externamente nem URL inventada. Configuração de produção/assinatura/provedores/URLs legais/processos de moderação/privacidade permanece externa. PR-08 tem pontos de extensão no mesmo post/comment/media, exigindo novo contexto/ACL e testes específicos; o contexto privado não foi criado antecipadamente.
