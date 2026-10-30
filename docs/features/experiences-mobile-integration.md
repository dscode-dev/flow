# Contrato mobile — PR-02.B

Implementar Experiences no Flutter existente, sem trocar Identity/Dio/Riverpod/router ou duplicar refresh. Fonte exata para cliente tipado: [OpenAPI 1.1.0](../../contracts/openapi/flow.yaml), schemas ExperienceInput, Experience, ExperiencePage, ExperienceCategory, CoverUploadInput, CoverUpload e CoverVerified. [Regras completas](experiences.md) e [ADR](../decisions/0009-experiences-lifecycle-media.md). Este documento não autoriza implementar participação/convites/check-in/feeds/Flows/chat/pagamento.

## Operações e payloads

Todas exigem bearer Flow; nenhum ID token social é aceito aqui. Erro é `{error:{code,message,request_id}}`. `Cache-Control: no-store`; manter dados privados só durante sessão/contexto autorizado.

| Método / path | Entrada | Saída |
| --- | --- | --- |
| GET /v1/experience-categories | nenhuma | 200 `{items:[{id,name,sort_order}]}` habilitadas |
| POST /v1/experiences | ExperienceInput parcial + Idempotency-Key UUID | 201 Experience, Location e ETag |
| GET /v1/experiences/{id} | id | 200 Experience e ETag, ou 404 uniforme |
| PUT /v1/experiences/{id} | **documento completo** ExperienceInput + If-Match | 200 Experience e novo ETag |
| POST /v1/experiences/{id}/publish | `{}` + If-Match | 200 Experience |
| POST /v1/experiences/{id}/cancel | `{}` + If-Match | 200 Experience |
| POST /v1/experiences/{id}/archive | `{}` + If-Match | 200 Experience |
| GET /v1/me/experiences | status?, limit?, cursor? | 200 ExperiencePage |
| GET /v1/experiences | category_id?, phase?, latitude/longitude/radius_m?, limit?, cursor? | 200 ExperiencePage público |
| GET /v1/experiences/{id}/cover | bearer, id | 200 bytes image/jpeg ou image/png; sem redirect |
| POST /v1/media/uploads | `{content_type,size_bytes}` + Idempotency-Key UUID | 201 `{media_id,upload:{method,url,fields,expires_at}}` |
| POST /v1/media/uploads/{id}/confirm | `{}` | 200 `{id,status:"READY",content_type,size_bytes,width,height,sha256}` |

ExperienceInput contém somente: title, description, category_id, visibility, starts_at, ends_at, timezone, location `{latitude,longitude}`, venue_name, address, capacity, external_ticket_url, cover_media_id. Todos opcionais em POST/PUT parcial: omissão tem semântica de **substituição/default**, nunca PATCH. null limpa category_id/starts_at/ends_at/timezone/location/capacity/ticket/cover; strings não nulas, vazias em rascunho. visibility ausente vira PRIVATE. Não enviar id/creator/status/phase/version/timestamps/location_type/moderation ou URL da imagem. Campos desconhecidos são 400; corpo máximo 32KiB.

Experience responde **todos os campos Input** mais id, creator_user_id, location_type=PHYSICAL, status, phase?, created_at, updated_at, published_at?, cancelled_at?, archived_at?, version e details_redacted. `?` nesta frase indica **valor nulo**, não ausência da propriedade. Strings vazias e opcionais null devem ser tratados no rascunho/histórico. Resposta não tem dados privados de Identity, contagem de participantes ou compra confirmada. ETag é uma string forte como `"3"`; conservar aspas e usá-la literalmente em If-Match. version JSON int64 deve ser tratado sem precisão perdida.

## Formulário, agenda e publicação

Carregar catálogo do servidor; não hardcode somente os labels do Flutter. Preservar categoria histórica ausente do catálogo habilitado sem permitir selecioná-la numa nova publicação. Texto normalizado no backend pode voltar diferente (trim/NFC); estado confirmado do servidor é a autoridade.

Draft parcial tem PRIVATE por padrão e pode não ter data/local/capa. Salvar via POST uma vez e PUT nas edições; associar cada tentativa de criação à mesma chave UUID e documento canônico. Manter chave/ID durante timeout ou resposta ambígua; mesma chave/corpo retorna snapshot original por 24h, não criar nova chave automaticamente. Se edição ocorreu, reconciliar ID com GET. Ao mudar intenção após falha confirmada, usar chave nova. Dois toques/submissões paralelos compartilham a mesma intenção e devem ser bloqueados/single-flight no cliente.

Publicar é ação explícita após revisão de título/descrição, categoria, agenda, fuso, ponto e venue. A pessoa escolhe o fuso IANA da experiência, independente do dispositivo. Converter data/hora civil para instantes UTC e lidar explicitamente com horários repetidos/inexistentes de DST; enviar RFC3339 Z ou +00:00. Nunca reinterpretar instantes do servidor na zona do aparelho ao salvar. Mostrar agenda na zona preservada, e duração/cross-midnight corretamente. Publicação aceita futuro ou LIVE, fim futuro, duração até 31d, início até 366d. Não calcular/armazenar status persistido baseado no relógio do aparelho; phase é apresentação derivada do servidor.

Publicada: permitir editar título/descrição/ticket/capa antes do fim, reenviando **sem alteração** agenda/local/fuso/venue/endereço/categoria/capacidade/visibilidade. Mostrar esses campos protegidos na UI. CANCELLED não restaura; ARCHIVED mantém histórico. PUBLISHED encerrada pode arquivar, não cancelar ou editar. POST transição sempre envia `{}`; não transmitir status no Input.

PUBLIC revela local/descrição às contas que descobrem; UNLISTED revela a qualquer conta autenticada com link após publicação e não é convite; PRIVATE somente autor. Mostrar essa consequência antes de publicar um endereço físico e evitar sugerir residência/local sensível como padrão. Não solicitar permissão de localização apenas para abrir formulário: seleção de ponto pode ser manual. Localização do dispositivo, mapa/Radar e geocoding requerem escopo/consentimento próprio; não antecipar trilha de localização.

## Capas reais

1. Escolher imagem já orientada e limitar JPEG/PNG, 1..5MiB, <=4096px por lado/12MP; validação local melhora feedback, servidor valida novamente. Nunca guardar EXIF/URL externa como capa aceita.
2. POST upload com MIME e **número exato de bytes**, chave UUID estável por tentativa lógica. Armazenar apenas media_id/estado temporário durante esse fluxo, sem registrar URL/fields/capacidade em logs/analytics.
3. Usar cliente HTTP de upload separado: multipart/form-data para upload.url, enviar **todos os fields** recebidos sem modificar e arquivo como `file` por último. Não enviar Authorization Flow, cookies da API ou interceptor de refresh ao storage. Não substituir host/porta/fields da resposta. Configuração do backend deve fornecer URL alcançável no emulador/aparelho.
4. Sucesso S3 2xx não torna capa válida. POST confirm pela API com bearer; só READY pode ser associada. Timeout de confirmação: pode repetir confirm com mesmo ID; expiração exige nova iniciação/chave e upload. Se servidor marcou inválido, não insistir no mesmo ID.
5. PUT condicionado com cover_media_id; ou incluir READY próprio no POST inicial. Sem PUT/POST confirmado a capa ainda não pertence à experiência e será removida como órfã após 24h. Não enviar staging URL, filename ou verified key ao domínio.
6. Exibir bytes de GET cover com bearer via mecanismo que preserve autorização e no-store; não usar cache global por UUID, persistir capas PRIVATE ou anexar bearer em query. Limpar imagem/dados ao sair/restringir sessão. Mudança de cover_media_id exige invalidar a memória da capa.

O servidor reencodifica removendo metadados; tamanho/hash finais podem diferir do upload. Não afirmar aprovação de conteúdo, antivírus ou pagamento. Não implementar vídeo, pipeline social ou P2P.

## Paginação, erros e reconciliação

Page tem items e next_cursor nulo no fim; limit padrão20/máximo100. Cursor assinado expira15min e liga usuário/filtros/limit; não reutilizar ao trocar filtros/conta. Ordenação own por criação DESC/ID DESC; público por starts_at ASC/ID ASC. Distância é filtro (100..100000m), não ordenação; latitude/longitude/radius_m devem ser enviados juntos. Query desconhecida, repetida ou vazia retorna400. Dados podem mudar entre páginas; deduplicar por ID e recarregar após mutação/retomada, sem promessa de snapshot ou total.

| Código HTTP / error.code | Comportamento esperado |
| --- | --- |
| 400 invalid_request | corrigir formato/campo/If-Match/query; não repetir payload inválido |
| 401 unauthorized | usar coordenador Identity existente; não retry automático de escrita; se renovar com segurança, reconciliar GET ou repetir criação explicitamente com chave original |
| 403 account_restricted / onboarding_required | bloquear ação e seguir estado Identity/onboarding; sem nova autenticação paralela |
| 403 publishing_restricted | informar indisponibilidade; não tentar publicar com outro visibility/ID |
| 404 not_found | indisponível/sem acesso; não afirmar existência nem abrir privada por UUID |
| 409 idempotency_conflict | chave reutilizada com outro corpo; reconciliar intenção/ID, sem gerar duplicata silenciosa |
| 409 protected_attributes / invalid_transition / draft_limit | respeitar campos/estado/limites; buscar estado atual |
| 412 version_conflict | manter edição local, GET novo e oferecer reconciliação; não sobrescrever versão alheia automaticamente |
| 428 precondition_required | corrigir cliente para enviar ETag forte |
| 413 payload_too_large / 422 experience_invalid | reduzir/corrigir dados; não expor erro SQL ou stack |
| 422 media_invalid / media_not_ready | rejeitar imagem/associação, confirmar ownership/READY ou escolher nova capa |
| 409 upload_not_pending / 410 upload_expired | reconciliar READY ou iniciar novo upload; não reutilizar autorização expirada |
| 429 rate_limited | respeitar Retry-After, manter formulário; teto diário UTC pode durar além do hint de60s |
| 503 media_unavailable / temporarily_unavailable | mostrar falha temporária; não criar mídia falsa/fallback com URL arbitrária |

Erros desconhecidos/enums novos: fallback seguro. Incluir request_id no diagnóstico categórico, nunca corpo/URL de upload/token/local exato. Ticket é link externo: avisar que compra ocorre fora do Flow, sem fetch de preview e sem convertê-la em RSVP.

## Critérios de aceite PR-02.B

Cliente tipado e telas de criar/salvar/retomar/detalhes/minhas/publicar/cancelar/arquivar com estados vazios/rede/restrição/conflito; catálogo real; caps e DST; upload S3+confirm+associação+download autorizados; limites/visibilidade; timeout/idempotência/concorrência; refresh existente sem repetir escrita ambígua; acessibilidade/texto ampliado/teclado/temas. Testar Flutter contra API Go/PostGIS/S3 reais no ambiente local/homologação, incluindo não autor e dados redigidos. Configurar endpoint S3 alcançável sem relaxar TLS em release. Provedores reais/IDs/HTTPS/brand continuam dependências externas declaradas no PR-01.C, sem bloquear desenvolvimento independente nem usar fixtures em produção.
