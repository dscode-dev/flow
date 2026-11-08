# Flows — PR-05

Apresentação visual subordinada à Experience, gerenciada no detalhe pelo proprietário em “Apresentação nos Flows”. Sem segundo cadastro de eventos/publicações pessoais, curtidas, followers, participação ou P2P. [ADR0010](../decisions/0010-explore-flows-exposure-media.md) define a exceção explícita de UNLISTED e a distribuição revogável.

## Elegibilidade

Experience publicada, VISIBLE, fim futuro, criador ativo e sem restrição de publicação, início até agora+FLOWS_WINDOW_HOURS (default48, 1..168). PUBLIC permite apresentação automática pela capa READY; pode ser desativada. UNLISTED exige configuração enabled e consentimento público explícito auditado; não há backfill. PRIVATE nunca entra. Mídia própria READY tem prioridade; imagem própria, poster do vídeo READY ou capa READY oferecem fallback autorizado. Vídeo em PROCESSING/FAILED não é servido; imagem/capa elegível pode continuar representando a Experience. Sem mídia visual READY não há Flow.

LIVE primeiro, depois starts_at/id; nenhuma contagem fictícia ou inferência de preço. Região legítima filtra raio, sem ranking de afinidade. Snapshot no cursor mantém ordem estável; fim/cancelamento/retirada/sessão são revalidados. Fases são calculadas pelo servidor. Mudanças remotas são vistas na próxima revalidação ou requisição de mídia; a UI vence itens em até60s ou na próxima fronteira temporal retornada, sem polling de descoberta.

## Endpoints (OpenAPI1.4.0)

| Método/recurso | Contrato |
| --- | --- |
| GET /v1/flows | categoria/região opcionais, limit1..50 default12, cursor, as_of/valid_until/window_hours, itens/next_cursor; URLs temporárias não são IDs |
| GET /v1/flows/{experienceId} | Revalida elegibilidade e renova apresentação/URLs30s |
| GET /v1/flows/{experienceId}/content?ticket=... | Capacidade temporária, sem Bearer do player; sessão/versões/eligibilidade verificadas em cada GET/range, no-store, bytes progressivos via S3; 200/206 |
| GET/PUT /v1/experiences/{experienceId}/flow | Owner, ETag próprio inicial0; If-Match obrigatório no PUT; enabled, consentimento explícito, image_asset_id/video_asset_id nullable; stale412 |
| POST /v1/experiences/{experienceId}/flow/media | Owner, Idempotency-Key UUID e MIME/tamanho; autorização POST S3 de5min, tamanho exato |
| POST .../flow/media/{mediaId}/confirm | Confirmação idempotente por mídia;202, enfileira sem transcodificar no handler |
| GET .../flow/media/{mediaId} | Owner, estado real e metadados/erro categórico; não expõe chave S3 |

PUT substitui referências: null remove. Só aceita nova mídia da mesma Experience/owner, tipo correto em PROCESSING/READY; referências já vinculadas com falha podem ser mantidas para diagnóstico/desativação. Desativar revoga consentimento e muda versão, invalidando capacidades anteriores. Reativar UNLISTED exige checkbox de descoberta pública. Imagem/vídeo recebido ainda precisa ser vinculado ao salvar a apresentação. Não há presigned GET permanente ou cache compartilhado de mídia.

## Pipeline e operação

`media.flow_assets`: UPLOADING → PROCESSING → READY/FAILED; DELETED para órfãos. Hash da intenção e lock da Experience serializam idempotência/ownership. Confirmar PROCESSING/READY repete estado sem criar job duplicado. Worker Go usa claim atômico SKIP LOCKED, lease100s, limite de três tentativas de processamento recuperáveis após crash (a próxima claim falha sem transcodificar), timeout90s e fencing/row lock na publicação do resultado. Um job por processo; escalar workers mantém claims seguros.

MIME permitido de entrada: JPEG/PNG (até5MiB), MP4/MOV (até32MiB e15s). FLOW_MEDIA_MAX_BYTES default33554432, entre1 e32MiB; FLOW_MEDIA_MAX_DIMENSION default1920, 320..4096. Limites físicos do sanitizador de imagem4096/12MP continuam. S3 exige tamanho/MIME declarados; worker lê conteúdo real limitado, decodifica/sanitiza imagem ou inspeciona vídeo com FFprobe e decodifica/transcodifica com FFmpeg. Entrada/saída de vídeo são verificadas; saída H.264/AAC, yuv420p, até1280px,30fps, faststart e posterJPEG512px, sem metadados originais. content_type do estado registra tipo de entrada; vídeo entregue é MP4. Rejeita tipo fingido, duração maior15s, dimensões e tamanho fora dos limites, stream/formato não suportado ou falha de processamento.

Ferramentas recebem só paths locais criados pelo worker, protocolos file/pipe, threads limitadas e saída de diagnóstico limitada1MiB, sem payload/erro bruto em logs. CPU1, memória512MiB, pids64, tmpfs128MiB, rootfs read-only, cap_drop ALL e usuário não root em Compose. Nenhum segredo Identity/SMS é passado ao worker. A imagem API inclui o executável worker/FFmpeg; é o mesmo backend Go, sem serviço público de vídeo ou auxiliar Python/Node.

`make mobile-local` inclui migrate/API/worker e preserva token Mapbox/dados/volumes. Worker não tem porta pública. Observar `docker compose --env-file .env -f infra/compose/compose.yaml logs --tail=100 flow-media-worker` (sem URLs/credenciais) e estado/idade/attempts no banco por operador autorizado. Não publicar nem copiar ambientes resolvidos com segredos. Falha de ferramenta/storage termina em estado categórico ou lease recuperável; FAILED exige nova seleção/upload. Se worker estiver desligado, estados ficam PROCESSING; API não finge mídia pronta.

Limpeza periódica do worker: staging após expiração+1h quando não PROCESSING; objetos finais sem associação após24h, lotes50 com locks. Tombstones7 dias, auditoria180 dias. Mídia associada permanece até remoção da referência; desativar/cancelar restringe leitura imediatamente em novas requisições, sem apagar evidência da Experience automaticamente. `make smoke` acompanha seis migrations e continua exclusivo de banco descartável/vazio; não executar no banco local com conta existente.

## Viewer e lifecycle

Carrossel imediatamente após header Explorar; “Ver todos” abre PageView vertical paginado. Somente item ativo cria player, anterior é descartado antes de inicializar o próximo. Áudio sempre mudo, sem loop; redução de movimento/leitor de navegação exige ação para play. Próximos vídeos não são pré-carregados; imagens são limitadas à janela dos widgets. Player pausa/descarta ao abrir detalhe, sair, background, troca de conta ou validade da capacidade. Retorno do detalhe preserva índice e revalida/renova mídia. URLs são resolvidas somente para a mesma origem da API e rota de conteúdo, sem abertura externa arbitrária. Erro/rede lenta permitem retry ou detalhe; sem ações falsas de curtir/seguir/participar/share.

Galeria seleciona imagens/vídeos; não solicita câmera/microfone ou GPS novo. Polling de processamento só enquanto a gestão está ativa, no máximo60 consultas espaçadas2s, cancelado em background/saída. Salvar/alterar não refaz o formulário Experience. HTTP de mídia local: NSAllowsLocalNetworking no iOS; Android cleartext somente quando FLOW_ENV não é production e API_BASE_URL é HTTP de endereço privado/local. Produção exige HTTPS pelo preflight e StorageConfig. Não foi habilitado NSAllowsArbitraryLoads.

## Validação e roteiro físico

Automação inclui PostGIS/S3/FFmpeg reais, bridge Flutter/Dio, controller/widgets e teste separado de player nativo em simulador quando habilitado. Os resultados observados e limites de homologação constam no [relatório PR-05](../architecture/pr-05-completion-report.md). Nenhum teste usa fixture de produção.

Com conteúdo real criado pelo próprio app e API alcançável, validar Android/iOS físico: busca/categoria/período/região e cursor; vazio/rede lenta/retry; carrossel→item correspondente/Ver todos; imagem, vídeo≤15s e rejeição>15s; poster/orientação/áudio mudo/redução de movimento; um player ao deslizar/paginar; detalhe/volta; background/retomada/conta; expiração30s/renovação e retirada remota; upload interrompido/retry/worker desligado; UNLISTED sem/ com/revogado consentimento e PRIVATE; memória/bateria/fluidez com aparelhos de referência. Não declarar performance/homologação física a partir dos builds ou do simulador.
