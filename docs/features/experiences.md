# Experiences — backend PR-02.A

Fonte HTTP: [OpenAPI 1.1.0](../../contracts/openapi/flow.yaml). Decisões: [ADR 0009](../decisions/0009-experiences-lifecycle-media.md). [Integração Flutter PR-02.B](experiences-mobile-integration.md). Escopo físico; não inclui RSVP, convites, check-in, Event Space, pagamentos, Flows viewer ou administração.

## Autoria e estados

Conta autenticada ativa pode ler; criar/editar/transicionar/upload exige onboarding completo. Identity continua autoridade de sessão/restrições e fornece sua operação transacional. Sem telefone/perfil social/subject externo nas respostas. Creator e timestamps são sempre definidos no servidor.

| Origem | Operação | Condições / efeito |
| --- | --- | --- |
| inexistente | criar | DRAFT versão 1; corpo parcial; PRIVATE por padrão; chave idempotente obrigatória |
| DRAFT | PUT | substitui documento editável, permitindo limpar opcionais; campos preenchidos já devem ser válidos |
| DRAFT | publicar | título >=3, descrição >=10, categoria habilitada, início/fim/fuso/ponto/venue >=2; fim futuro, início até 366 dias; quota e restrição |
| PUBLISHED antes do fim | PUT | só título, descrição, ticket e capa; agenda/fuso/local/endereço/venue/categoria/capacidade/visibilidade protegidos |
| DRAFT ou PUBLISHED antes do fim | cancelar | CANCELLED; sem restore; mantém histórico |
| DRAFT, CANCELLED ou PUBLISHED encerrada | arquivar | ARCHIVED; ID/timestamps/histórico mantidos |
| CANCELLED/ARCHIVED | editar/publicar | 409 invalid_transition |

If-Match obrigatório em PUT/transições; ausente 428, malformado 400, desatualizado 412. O lock valida dono antes da versão/estado: recurso alheio recebe 404. Repetição de transição com **versão atual** e estado já alvo é no-op; repetir versão antiga recebe 412. PUT idêntico normalizado não altera versão/evento. Mudanças reais incrementam versão e geram exatamente uma auditoria e um evento no commit.

UPCOMING: agora < starts_at. LIVE: starts_at <= agora < ends_at. ENDED: agora >= ends_at. phase=null fora de PUBLISHED. Não há cron para mudar estado por passagem do tempo; finalizar é arquivar a experiência encerrada. Publicar algo já LIVE é permitido; publicar encerrado não. Duração (instantes) >0 e <=31 dias; rascunho aceita início ou fim isolado, mas ambos presentes precisam estar ordenados. Fuso IANA explícito, UTC permitido, Local/abreviação/offset como fuso recusados. Enviar instantes UTC (Z ou +00:00); saída em Z. DST, meia-noite, ano e país não alteram a aritmética dos instantes.

## Audiência e privacidade

| Conteúdo | Criador autenticado | Outra conta autenticada | Descoberta |
| --- | --- | --- | --- |
| qualquer DRAFT | completo | 404 | nunca |
| PRIVATE, qualquer estado | completo | 404 | nunca |
| PUBLIC/PUBLISHED/VISIBLE | completo | completo | sim, enquanto fim futuro |
| UNLISTED/PUBLISHED/VISIBLE | completo | direto por ID/link | nunca |
| PUBLIC/UNLISTED histórico já publicado | completo | resumo redigido | nunca |
| WITHHELD | completo | 404 | nunca |

Histórico redigido: details_redacted=true; description/venue_name/address vazios; location/capacity/external_ticket_url/cover_media_id nulos. Título, ID, autor opaco, categoria, agenda e timestamps continuam identificando o evento. Um draft cancelado/arquivado sem published_at continua só do autor. Não se infere convite/membership por UUID, ticket ou login. Future Participation deve fornecer `canViewExperience` explícito com escopo/expiração/revogação antes de liberar PRIVATE a outros módulos. Não mudar essa regra no cliente.

PUBLIC e link UNLISTED publicados divulgam coordenadas/venue/endereço/descrição às contas autorizadas; o formulário de publicação deve mostrar essa consequência. Não tratar UNLISTED como confidencial entre membros. Coordenadas persistidas em geography(Point,4326), arredondadas a seis decimais (~0,11m no equador); endereço livre opcional só para exibição, sem geocoding reverso. Experiência física exige ponto e venue ao publicar. Não armazenamos trilha de localização do usuário, origem de buscas ou device timezone.

## Escritas, quotas e categorias

POST `/v1/experiences` exige Idempotency-Key UUID, escopo conta/operação; hash do documento normalizado e snapshot da criação são duráveis por 24h. Mesma chave/conteúdo retorna o snapshot original 201/Location/ETag, inclusive após edições; reconciliar com GET. Corpo diferente retorna 409. Chave diferente significa nova intenção; o servidor não tenta adivinhar duplicatas por título/data. Flutter deve conservar a chave durante tentativas/reinício controlado. Conta serializada impede duas criações simultâneas com a mesma chave.

Quotas configuráveis: EXPERIENCES_CREATE_DAILY=20, EXPERIENCES_PUBLISH_DAILY=20, EXPERIENCES_UPLOAD_DAILY=30, EXPERIENCES_MAX_DRAFTS=50. Contadores por conta/dia UTC; só operações novas confirmadas consomem quota. Falhas de validação/idempotência/no-op não contam. Origem HTTP também limitada pelo Identity, sem confiar em headers de IP. Quota excedida 429, Retry-After conservador 60s; quota diária pode durar até a próxima meia-noite UTC. DRAFT máximo retorna draft_limit 409; cancelar/arquivar libera vaga. Não há aprovação manual para publicar.

Categorias seed: music, party, culture, sport, gastronomy, nature, tech, education, community. GET `/v1/experience-categories` lê habilitadas, ordenadas por sort_order/id; rótulos são dados. Categoria desabilitada impede novas escolhas/publicação; publicação antiga mantém referência histórica e pode corrigir título sem recategorizar. Não apagar categoria referenciada. Gestão privilegiada exigirá API própria/auditoria; ainda não existe.

Texto NFC, trim, limites por runes (título 120, descrição 5000, venue 160, endereço 300), controles/bidi recusados; descrição permite LF/tab. JSON estrito, corpo <=32KiB, sem campos arbitrários/owner/status/timestamps do cliente. Capacidade opcional 1..1.000.000 é informativa; não reserva vaga. Ticket aceita apenas HTTPS/DNS ASCII ou punycode, porta padrão/443, sem userinfo/fragmento/IP/localhost; nenhum fetch, preview, resolução DNS, pagamento ou comprovação de participação.

## Descoberta e próximos módulos

GET `/v1/experiences`: estado PUBLISHED + PUBLIC + VISIBLE, fim futuro. Filtros category_id, phase UPCOMING/LIVE, latitude/longitude/radius_m juntos (100..100000m). PostGIS ST_DWithin usa geodésica e índice GiST; não faz ranking/nearest-neighbor. Ordem starts_at,id ASC. GET `/v1/me/experiences`: somente autor, filtro status opcional, created_at,id DESC, inclui histórico/retenção de moderação. limit padrão 20, máximo 100, cursor HMAC ligado a principal/filtros/limite, expira em 15min. next_cursor=null no fim; não há total/offset ou snapshot de longa duração. Query duplicada/desconhecida/vazia é inválida.

`experiences.discovery` é visão SQL sem estado separado. Rebuild é recrear a visão a partir do agregado; cancelamento/arquivo/WITHHELD não dependem de consumidor. Futuro índice externo deve transportar versão, receber invalidações/tombstones e revalidar fonte antes de expor detalhes/capas.

| Consumidor futuro | Contrato e limite |
| --- | --- |
| Home | candidatos públicos elegíveis, sem recomendador ou sinais pessoais neste PR |
| Radar | filtro PostGIS acima; coordenada consultada transitória, consentimento/UI no ciclo mobile |
| Explore | catálogo/filtros e IDs autorizados; busca textual/ranking futura |
| Flows | elegibilidade de descoberta configurável em política futura; não ampliar PRIVATE/UNLISTED por padrão |
| Participation | consulta autorizada do agregado/versão/agenda/capacidade; RSVP/quotas ocupadas e membros pertencem a outro domínio |
| Event Space | usa elegibilidade Participation, não UUID ou ticket; nenhum feed/chat atual |
| Notifications | consome fatos mínimos, resolve destinatários/audiência em contrato próprio; sem push público com local/texto privado |

Outbox: experience.created/published/updated/cancelled/archived, schema_version=1, aggregate_id=experience.id. Payload [schema específico](../../contracts/events/experience-payload.schema.json): experience_id, version, status, visibility; sem título/local/ticket/capa/PII. Agregado/auditoria/evento/idempotência compartilham transação. Sem evento em no-op/erro/rollback. Consumidores futuros deduplicam event_id e ignoram versões antigas, ressincronizam por fonte autorizada. Sem relay/broker publish, DLQ, ordenação global ou consumidor implementados.

## Operação

`make env` adiciona segredos S3 locais sem imprimir valores nem sobrescrever configuração existente; `make up` inclui storage privado SeaweedFS e volume media-data. Só porta S3 é publicada em loopback; consoles/filer não são expostos. Host/app nativo precisa alcançar MEDIA_S3_PUBLIC_ENDPOINT, preservando a assinatura e todos os fields; não substituir hostname no cliente. Emulador/aparelho exige configuração de endpoint alcançável própria; localhost do desktop não serve automaticamente no dispositivo.

`make experiences-maintenance` remove staging expirado há mais de 1h, apaga objetos READY/UPLOADING/REJECTED sem bindings com idade >24h e marca tombstone; limpa idempotência24h/quotas>2d, tombstones DELETED>30d e auditoria>180d. Lock SKIP LOCKED/binding serializa limpeza com associação; arquivos associados sobrevivem. Executar pelo menos de hora em hora em produção, com conta operacional/alerta e lifecycle de staging no bucket para capturar uploads tardios iniciados antes da expiração. Rodada limitada a100 registros; repetir até zerar backlog, sem reverter dados de produto. Não há apagamento automático de experiências/histórico nem promessa de direitos de eliminação resolvidos. Decodificação/reencodificação limitada a duas confirmações simultâneas por instância; saturação retorna media_unavailable503 sem fila ilimitada.

Storage não configurado: uploads/capas retornam media_unavailable 503; experiências sem capa continuam. Configuração parcial falha no startup. Produção exige HTTPS nos endpoints, bucket privado com bloqueio de ACL/policies públicas, credencial mínima por prefixo (POST staging, Get/Delete staging, server-only Put/Get/Delete verified), CORS específico se houver cliente web, lifecycle/criptografia/backup/limites e homologação no provedor selecionado. Sem cloud provisioning neste PR.
