# Relatório de execução — PR-05 Explorar e Flows

08/11/2026, America/Recife. Implementação Go/Flutter no repositório, sem staging, commit, push, merge ou deploy externo. Evidências abaixo distinguem processamento real de mídia, integração HTTP, builds e player nativo; nenhuma homologação física ou performance de produção é presumida.

## 1. Estado inicial do Git

`main`, HEAD `1b7c5f7f262a0bc89c13e76e136a9d9d222f09e2` (título preexistente “implementa PR-03”), árvore/índice limpos. Os ciclos anteriores já estavam incorporados. [Inspeção inicial](pr-05-initial-review.md). Configuração privada/token Mapbox, conta temporária de desenvolvimento, SDK fixado, assinatura pessoal e volumes preservados. Nenhum commit foi criado pelo agente.

## 2. Arquivos alterados

| Grupo | Novos / modificados |
| --- | --- |
| Experiências/descoberta Go | Novos `backend/internal/experiences/explore.go`, `flows.go`, `flows_http.go`; configuração, registro HTTP e campos opcionais de cursor no serviço existente |
| Mídia Go | Novos `backend/internal/media/flow_assets.go`, `flow_worker.go`, `flow_stream.go`, `backend/cmd/flow-media-worker/main.go`; Service/boot da API configuram limites, Storage S3 e sanitizador existentes reutilizados |
| Banco/sqlc | `backend/migrations/00006_explore_flows.sql`, `queries/explore_flows.sql`, `queries/flow_media.sql`, gerados correspondentes e `dbgen/models.go`/`querier.go` |
| Flutter | Novos `apps/mobile/lib/features/explore/`: discovery_model/repository/controller, explore_page, flow_image/playback/upload/management_page e flows_viewer_page; repository central, router, atalho na Home, detalhe owner e explicação UNLISTED |
| Dependências/nativo | pubspec/lock com video_player; Android Gradle/Manifest para HTTP local condicionado; Info.plist com finalidade de galeria audiovisual e NSAllowsLocalNetworking, sem exceção ATS global |
| Testes | `apps/mobile/test/explore_flows_test.dart`, `integration_test/flows_native_test.dart`, bridge Experiences ampliado e fake central compatível; Go integration explore_flows/flows_native e worker test-only do bridge |
| Operação | `.env.example`, Compose worker/limites, Dockerfile com executável/FFmpeg, smoke somente vazio acompanha migration00006 |
| Documentação | Este relatório, revisão inicial, ADR0010, guias Explorar/Flows, READMEs, registro ADM-034–038 e inventário de dados |

Arquivos locais de configuração e artefatos/logs permanecem fora do Git. Arquivos dos ciclos anteriores foram modificados somente nos pontos de integração necessários; Radar não foi reimplementado ou refatorado esteticamente.

## 3. Endpoints e contratos

OpenAPI **1.4.0, 42 operações**, nove novas operações. Todos os paths e schemas anteriores foram comparados estruturalmente contra HEAD e permanecem iguais; nomes exclusivos nas novas âncoras YAML evitam alterar aliases Identity existentes. Contrato validado pelo verificador Go e pelas respostas da integração real.

- `GET /v1/explore/experiences`: busca/filtros/cursor.
- `GET /v1/flows` e `GET /v1/flows/{experienceId}`: feed paginado/apresentação elegível.
- `GET /v1/flows/{experienceId}/content?ticket=...`: streaming autorizado, Range200/206, no-store.
- `GET/PUT /v1/experiences/{experienceId}/flow`: owner, configuração e ETag próprio inicial0/If-Match, stale412.
- `POST .../flow/media`, `GET .../flow/media/{mediaId}`, `POST .../flow/media/{mediaId}/confirm`: autorização S3 idempotente, estado, confirmação assíncrona202.

Mesma Identity/Dio/sessão, limites de origem/envelopes; nenhum mecanismo paralelo de login ou endpoint de fixture na aplicação. [Contratos completos](../features/flows.md).

## 4. Regras de elegibilidade

Flow é apresentação 1:1 de Experience, não entidade de evento/publicação independente. PUBLIC publicada pode usar automaticamente capa READY. UNLISTED só com enabled e aceite explícito de descoberta pública registrado por UTC/ator e auditoria com snapshot de audiência/refs/versão. Sem migração/backfill de consentimento. PRIVATE nunca entra, mesmo com flag enviada. Desativar revoga aceite e capacidades antigas; reativar UNLISTED exige novo aceite.

Exige PUBLISHED/VISIBLE, criador ativo/sem restrição de publicação, fim futuro, início dentro de FLOWS_WINDOW_HOURS (default48,1..168) e imagem/poster/capa READY. Lifecycle/retirada/moderação/conta e sessão são verificadas em SQL, sem composição pública cacheada. Imagem própria tem prioridade, depois poster de vídeo pronto e capa autorizada. Vídeo PROCESSING/FAILED não é servido; fallback autorizado pode continuar elegível. LIVE primeiro, depois início/ID; cursor fixa snapshot da ordem e a elegibilidade atual continua sendo aplicada. [ADR0010](../decisions/0010-explore-flows-exposure-media.md).

## 5. Implementação da busca

Explorar reutiliza `experiences.discovery`: PUBLIC/PUBLISHED/VISIBLE e fim futuro; consentir Flows não inclui UNLISTED na busca/Home/Radar. Título/descrição via tsvector armazenado, normalização unaccent/português, GIN parcial e websearch_to_tsquery parametrizada. Ordem starts_at/id, cursor HMAC por conta/filtros/tipo, limit+1, até50 resultados, timeout2s. Sem mecanismo externo, consulta ilimitada ou N+1 de busca.

Categoria, LIVE/UPCOMING, intervalo UTC por sobreposição até31 dias e região/raio opcionais1–100km. Query estrita, finitude, limite de texto120 caracteres, pares/trios obrigatórios e valores duplicados/desconhecidos rejeitados. Sem preço no modelo: não foi inventado filtro gratuito/pago a partir do link de ingresso. Região aproximada escolhida, sem GPS obrigatório/histórico. Mobile debounce350ms, dedup/cancelamento/geração, paginação real e descarte temporal de resultados com relógio do servidor.

## 6. Widget e visualizador Flows

Carrossel imediatamente depois do header Explorar, antes da busca; cards proporcionais com imagem real/LIVE/Em breve e “Ver todos”. Sem estado “visualizado” ou números sociais inventados. Viewer vertical paginado em `/flows`, seleção do carrossel em `/flows/{id}`, contexto e detalhe existente. Estado/câmera Radar preservados; nenhuma página futura simulada.

video_player oficial **2.14.1** (resolvido no lock), um player visível/ativo; inicialização serializada após dispose anterior, mudo e sem loop, sem pré-carregar vídeos fora de tela. Redução de movimento/navegação acessível exige play explícito. Pausa/descarte por rota, background, conta e expiração de capacidade; retorno do detalhe revalida e mantém índice enquanto os itens continuam válidos. Imagens ficam na memória limitada dos widgets e limpam pixels na troca de conta/background. Erro/retry/renovação/vazio e fim da paginação são explícitos. Layout320px/texto200%/temas coberto pelos testes focados.

Gestão contextual “Apresentação nos Flows” no detalhe owner, sem refazer formulário Experience: escolher imagem/vídeo, upload/retry, processamento real, associar/remover mídia, consentir e ativar/desativar. Polling de processamento somente na gestão ativa, no máximo60 consultas a cada2s e encerrado ao sair/background. Salvar vincula a mídia; upload sem associação torna-se órfão. Compartilhamento externo não foi implementado porque não existe deep link HTTPS aprovado.

## 7. Processamento de mídia

Upload POST no S3 existente, tamanho/MIME/expiração5min e quota/idempotência do owner. Confirmar muda estado persistido para PROCESSING, sem transcodificar no handler. Worker Go no mesmo backend/imagem: claim SKIP LOCKED, lease100s, timeout90s, um job por processo, fencing/lock antes da escrita READY; estados READY/FAILED/DELETED reais. Retomada após crash é limitada por attempts.

JPEG/PNG até5MiB e sanitizador existente; MP4/MOV até32MiB/15s com FFprobe/FFmpeg reais, validação de entrada e saída, H.264/AAC/yuv420p/30fps/até1280px, faststart e poster JPEG, metadados originais removidos. Resolução de entrada default1920, configurável320..4096; teto32MiB, saída/diagnósticos/tempo/protocolos/threads limitados. Container não root, rootfs read-only, CPU1/memória512MiB/pids64/tmpfs128MiB. Worker recebe somente configuração DB/S3/mídia, sem segredos Identity/SMS. Sem backend auxiliar Python/Node, P2P ou live streaming.

S3 é privado. Capacidade API30s por sessão/conta/recurso/versões, renovada pelo GET Flow; cada GET/range reavalia autorização atual e faz streaming, sem carregar o vídeo inteiro no Flutter ou emitir URL S3 irrevogável. Bytes já entregues e respostas em andamento não podem ser recuperados. Limpeza em lotes: staging expiração+1h, finais não associados24h, tombstones7 dias e auditoria180 dias; mídia vinculada não é apagada só por encerrar a experiência. [Operação do worker](../features/flows.md#pipeline-e-operação).

## 8. Segurança e privacidade

Ownership da Experience e da mídia, tipo/estado e versão verificados no backend; flags não ampliam PRIVATE. Sem identidade privada, GPS obrigatório, trilhas, tracking oculto de views, analytics de busca ou dados fictícios de produção. URLs/texto/coords/tokens e erros brutos de mídia não são logados. Protocolos locais no subprocesso, credenciais do servidor não entram no app. Inspeção técnica de arquivo não equivale a moderação audiovisual ou revisão jurídica/LGPD.

Galeria seleciona mídia; sem novas permissões de câmera/microfone/background. iOS permite rede local via ATS específico; Android condiciona HTTP a ambiente não production e origem privada/local, produção permanece HTTPS. Atribuição/Mapbox do PR-04 não foi alterada. Inventário de [governança](../privacy/data-governance.md) atualizado e limites de revogação/caches explícitos.

Inspeção dos artefatos nativos confirmou localização aproximada no Android, sem localização precisa/em background, câmera ou microfone; o player acrescenta WAKE_LOCK sem solicitação de permissão em runtime. No iOS, ATS local está habilitado sem NSAllowsArbitraryLoads, mantendo somente localização durante uso e galeria, sem modos de execução em background.

## 9. Testes realmente executados

| Verificação | Resultado observado |
| --- | --- |
| Go | gofmt, vet e testes dos módulos Experiences/Media e cmd API/worker aprovados |
| Contratos | OpenAPI/JSON Schemas válidos; sqlc regenerado; comparação estrutural dos paths/schemas antigos sem alteração |
| PostGIS/S3/FFmpeg | Três testes focados aprovados,7,051s: busca sem acento/filtros/cursor/ordem; consentimento/retirada/PRIVATE/UNLISTED; janela/conta/restrição/ownership/auditoria; vídeo real/poster/range, >15s e MIME falso rejeitados; revogação de sessão e limpeza |
| Bridge Flutter real | Aprovado, Go25,317s/um caso Flutter; Radar/Home/CRUD/capas anteriores preservados, busca, upload Flow via Dio/S3, worker real, associação/READY/leitura e desativação |
| Flutter | Analyzer sem issues;18 testes únicos aprovados: seis novos e regressões Home/navegação; cancelamento/dedup, conta, player serializado, carrossel, paginação/pausa/detalhe, vazio/erro, temas320px/200% e consentimento. Após o ajuste final de contraste do viewer, os seis testes focados passaram novamente (35s), e o analyzer permaneceu sem issues |
| Docker/local | Imagens API/worker construídas; `make mobile-local` aprovado; API healthz200/readyz200, worker ativo com limites efetivos conferidos |
| Concorrência real | TestFlowUploadConcurrentIdempotency aprovado,8,703s do pacote: duas autorizações mesma chave→um upload, confirmações→um job, dois workers→um processamento/evento READY |
| Runtime de player | Retry aprovado em iPhone15 Pro/iOS17.5 simulador: Go161,316s, Xcode87,4s, um caso nativo; MP4 de2s gerado/transcodificado realmente, URL/API/S3 reais, dimensões/duração, áudio mudo/sem loop, posição avançou e pause funcionou. A tentativa inicial excedeu10min; harness corrigido8min/cancelamento de grupo/log persistido antes do retry |
| Builds afetados | Android APK debug aprovado (44,5s) e iOS debug para simulador aprovado (39,2s), ambos após o último ajuste Flutter e com configuração local privada; sem distribuição/instalação física |

Testes reais usam somente `flow_experiences_test`/bucket `flow-experiences-test`, com guarda e rollback/up de migrations preservando Identity/PostGIS. Nenhum smoke destrutivo no banco principal, interrupção Redis, suíte global repetida, fixture no app ou instalação física. Logs locais temporários `/private/tmp/flow-pr05-*`, sem versionamento. Código do teste nativo vive somente em integration_test/binário de testes Go.

Rotas novas de listagem no backend local retornaram401 sem autenticação; objetos/view/índice novos foram conferidos no banco atualizado. `git diff --check`, sintaxe dos scripts e links locais dos novos guias/ADR/relatório passaram. Branch/HEAD permanecem os mesmos e o índice está vazio.

## 10. Pendências externas

Homologação física Android/iOS: galeria/orientação/codecs/áudio/permissões, rede móvel e instável, expiração/renovação, bateria/fluidez/memória e troca de conta. Resultado do player em simulador é separado de homologação física. O [roteiro](../features/flows.md#validação-e-roteiro-físico) está preparado. Nenhum benchmark de carga foi alegado.

Continuam configuração/distribuição de produção, IDs/assinatura, Google/Apple/Twilio, HTTPS/origem/deep links, marca/URLs legais e revisão audiovisual/menores/custos/retencão. Token Mapbox foi informado como gerado, mas runtime Radar com token/homologação PR-04 continuam sem comprovação neste ciclo. Não foram criadas credenciais, origem legal ou dados de produção inventados.

## 11. Capacidades administrativas documentadas

[ADM-034–038](../admin-capabilities.md): elegibilidade/consentimento/retirada, diagnóstico/retry/moderação audiovisual, janela/categorias/ordenação/curadoria, monitoramento de transcodificação/limites, auditoria/custo de armazenamento/distribuição. Documentação distingue capacidades atuais (configuração, SQL/auditoria, estados/worker/limpeza) das permissões/painéis futuros. Nenhum painel administrativo foi construído.

## 12. Status técnico do PR-05

PR-05 tecnicamente concluído no ambiente local: implementação integrada, validações de domínio/HTTP/mídia real, player nativo em simulador, análise estática e builds Android/iOS aprovados. Homologação física e preparação de produção permanecem pendentes conforme seção10. Backend local atualizado sem recriar volumes/conta. Branch `main`, HEAD `1b7c5f7f262a0bc89c13e76e136a9d9d222f09e2` e índice vazio preservados; alterações disponíveis na árvore de trabalho para revisão. Para atualizar o app em `apps/mobile`, após a API estar pronta:

```sh
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

Não há push, merge, distribuição ou deploy externo autorizados/executados.

## 13. Preparação para PR-06 — Participação e Agenda

Reutilizar IDs/agenda UTC/IANA, lifecycle/audiência, detalhes e sessões. Participação exige agregado/contratos próprios de RSVP, elegibilidade, capacidade, conflitos, idempotência, cancelamento e auditoria; não inferir presença/vaga de views ou capacidade informada. Agenda precisa refletir alterações/cancelamentos autorizados e definir privacidade/retencão, sem alterar descoberta nem expor PRIVATE. Não foram criados handlers/contagens/ações de participar ou agenda social por antecipação.
