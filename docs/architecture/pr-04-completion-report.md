# Relatório de execução — PR-04 Radar

08/11/2026, America/Recife. **Trabalho independente do token implementado e validado localmente. A renderização Mapbox real e a homologação física continuam como gates externos; o DoD completo não foi declarado.** O proprietário confirmou que ainda não possui token. Sem staging, commit, push, merge, deploy ou instalação física neste ciclo.

## 1. Estado inicial do Git

Branch `main`, HEAD `f7fcab2dd996ac95f1fb80eb04d017c896a51359` (`PR-03 Parcial`). Única alteração inicial: `docs/architecture/pr-03-completion-report.md`, registro da retomada anterior, preservado. O commit já existia antes deste trabalho. [Inspeção inicial](pr-04-initial-review.md) registra a arquitetura e as fontes consultadas. SDK fixado, configuração LAN, conta temporária de desenvolvimento, assinatura pessoal iOS e volumes existentes foram preservados. Índice Git permaneceu vazio.

## 2. Arquivos criados e modificados

Novos:

- Backend: `backend/internal/experiences/radar.go`, `radar_test.go`, `integration/radar_test.go`; `backend/queries/radar.sql`; `backend/internal/platform/database/dbgen/radar.sql.go`; `backend/migrations/00005_radar_viewport.sql`.
- Flutter: `apps/mobile/lib/features/radar/radar_config.dart`, `radar_model.dart`, `radar_controller.dart`, `radar_map.dart`, `radar_location.dart`, `radar_page.dart`.
- Testes Flutter: `apps/mobile/test/radar_controller_test.dart`, `radar_widgets_test.dart`, `support/radar_fakes.dart`.
- Documentação: este relatório, `docs/architecture/pr-04-initial-review.md`, `docs/features/radar.md`.

Modificados:

- Backend: `backend/cmd/api/main.go`, `backend/internal/experiences/config.go`, `http.go`, `backend/internal/platform/database/dbgen/querier.go`.
- Contrato/operação: `contracts/openapi/flow.yaml`, `.env.example`, `infra/compose/compose.yaml`, `scripts/smoke.sh`, `scripts/auth-readiness.py`, `scripts/mobile-config.py`, `scripts/test_mobile_config.py`, `flutterw`.
- Flutter compartilhado: `apps/mobile/lib/core/navigation/router.dart`, `apps/mobile/lib/features/home/home_page.dart`, `apps/mobile/lib/features/experiences/data/experiences_repository.dart`, `apps/mobile/test/experiences_contract_test.dart`, `apps/mobile/test/support/experience_fakes.dart`.
- Dependências/configuração nativa: `apps/mobile/pubspec.yaml`, `pubspec.lock`, `config/auth.public.example.json`, `android/gradle.properties`, `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`, os dois `Package.resolved` de `ios/Runner.xcworkspace/xcshareddata/swiftpm/` e `ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`.
- Documentação: `README.md`, `apps/mobile/README.md`, `docs/admin-capabilities.md`, `docs/privacy/data-governance.md`, `docs/architecture/experiences-database.md`, `docs/features/home-discovery.md`.

O relatório PR-03 aparece no diff por alteração anterior, não por reescrita neste ciclo. Arquivos privados locais continuam ignorados; nenhum token Mapbox foi criado/inserido. Gerados de build/cache não são entrega versionada.

## 3. API e contratos

`GET /v1/radar/experiences`, autenticado pela mesma sessão Identity, no módulo Experiences existente. OpenAPI **1.3.0, 33 operações**. `bbox` e `zoom` obrigatórios; categoria, fase LIVE/UPCOMING, intervalo UTC e centro/raio opcionais. Validação estrita de parâmetros, duplicação, finitude, tamanho, faixa e combinações. Erros usam o envelope existente; consulta ampla recebe `400 radar_area_too_large`.

Resposta compacta com `as_of`, `valid_until`, limites efetivos, `items` e `truncated`. Marcadores incluem ID/versão, título/categoria, ponto autorizado, agenda/fuso/venue, referência de capa, fase e indicador de ingresso externo. Não expõe Identity privado, participantes, contagem total ou métricas inventadas. `Cache-Control: no-store`, JSON até 1 MiB, contexto de consulta de 2s. Defaults: 100 resultados, zoom mínimo 4, amplitude máxima 30 graus; teto absoluto 200. [Contrato e regras completos](../features/radar.md).

## 4. Queries geográficas

Uma query sqlc sobre `experiences.discovery`, com categoria no mesmo statement. `ST_Intersects(point::geometry, envelope)` respeita retângulo lon/lat; west > east divide a área no antimeridiano. Latitude Mercator limitada a ±85.051129; longitude ±180. `ST_DWithin` em geography mantém distância em metros. Ordenação determinística `starts_at,id`; `limit+1` determina truncamento sem consulta de total.

Migration 00005 acrescenta índice GiST parcial da expressão geometry; preserva o índice geography e as migrations anteriores. A visão central exige PUBLIC/PUBLISHED/VISIBLE; Radar exige fim futuro. PRIVATE, UNLISTED, draft, canceladas, arquivadas, retidas e encerradas são excluídas também para o criador. Sem N+1, novo banco, cache Redis ou indexador assíncrono. Testes reais verificam fronteiras e existência do índice; não representam benchmark de carga ou garantia de plano para qualquer cardinalidade.

## 5. Flutter e Mapbox

Rota protegida `/radar`, acesso pela Home, SDK oficial **mapbox_maps_flutter 3.34.2** e geolocator resolvido **14.1.2**, compatíveis com Flutter 3.47.8/Dart 3.13.7 e iOS 15 existentes. SDKs nativos travados em Maps/Core 11.34.2 e Common 24.34.2 nos lockfiles SPM. Sem framework novo de HTTP/estado: repository/Dio, Identity, Riverpod e router existentes.

MapWidget nativo com GeoJSON/style layers e estilos claro/escuro. Sem token público, mostra configuração indisponível, sem instanciar mapa ou consultar uma área fictícia. Configuração pública local e preflight recusam token secreto/administrativo/download. Wordmark e atribuição nativos ficam no topo, acessíveis acima da prévia; opt-out permanece o do fornecedor. Seu funcionamento real ainda precisa do gate de runtime.

AGP 9.1 usa `android.builtInKotlin=true`, necessário ao SDK atual. O build passa; Flutter ainda emite aviso sobre o ramo condicional de KGP legado no plugin Mapbox. Não houve patch no pub-cache ou troca desnecessária de versões. Não declarar compatibilidade com futuras versões do Flutter com base nesse build.

## 6. Filtros, pins e clustering

Categoria real, fase LIVE/UPCOMING, dias/período até 31 dias e raio 1–100km de referência fixa; limpar filtros, região manual e lista acessível da mesma fonte. Clusters nativos radius 48/maxZoom 16 contam somente marcadores recebidos; truncamento é visível. Ícones de categoria/fallback, borda LIVE e anel de seleção por layer; sem widget por marcador, pulso contínuo, popularidade ou contagem social.

Seleção revalida a área e o detalhe/capa existentes. Prévia permite somente a ação real “Ver detalhes”; retorno preserva câmera e revalida. Experiência retirada/expirada/restrita não mantém prévia antiga. Falha de capa revalida uma vez por versão/ref. Câmera e filtros de outra conta não reaparecem; sheets da conta anterior são fechados e a superfície nativa é recriada. Renderização e interação dos pins/clusters no SDK ainda não foram observadas com token real.

## 7. Privacidade da localização

Sem pedido de GPS na entrada. Ação explícita, explicação contextual e permissão durante o uso; negação/revogação/serviço desativado mantêm região manual. Um primeiro fix de baixa precisão, cancelável, timeout de 12s, sem puck/stream persistente/background. Ponto arredondado a duas casas antes de centralizar/enviar. Sem trilha, inferência por IP/telefone, altitude, velocidade ou logs de coordenadas/tokens.

Para localização, APK inspecionado declara somente `ACCESS_COARSE_LOCATION`, sem FINE/BACKGROUND/FOREGROUND_SERVICE_LOCATION. Info.plist compilado: somente `NSLocationWhenInUseUsageDescription`, sem Always ou modo background; wrapper aplica a opção oficial SPM de exclusão Always. Mapbox ainda recebe IP, informações técnicas e recursos da área exibida; cache/telemetria são do SDK. Isso está explicitado no [inventário](../privacy/data-governance.md), sem promessa de anonimato ou conformidade jurídica concluída.

## 8. Performance e comportamento de câmera

MapWidget estável entre atualizações; gestos e zoom nativos. Idle captura bounds/câmera; debounce de 350ms, cancelamento, chave de deduplicação e geração descartam respostas antigas. Repetir refresh enquanto a mesma consulta está em andamento não cria outra. Tema reinstala fontes/layers com geração de estilo e sincronização serializada; falha de fonte encerra sincronização e oferece reload explícito, sem loop automático de erro.

Sem polling: timer único remove fonte/seleção no menor limite entre 60s e a próxima fronteira temporal retornada; atualização manual ou retorno/resume reconsulta. Background/conta/dispose cancelam operações. Câmera fica em memória da conta; default sem contexto é visão geral 0/0, zoom 2, com pedido de aproximação. Métricas locais: duração HTTP/itens/canceladas/obsoletas/erros e proxy fonte→próximo frame FULL. Esse proxy não prova pins visíveis, bateria ou fluidez física. Nenhum benchmark foi alegado.

## 9. Testes e builds executados

| Verificação | Resultado observado |
| --- | --- |
| Go | gofmt; `go vet ./internal/experiences/... ./cmd/api`; `go test ./internal/experiences/... ./cmd/api`, aprovados |
| Contratos | OpenAPI válido; schemas events/realtime/lifecycle válidos; sqlc regenerado |
| PostGIS real | `FLOW_EXPERIENCES_TEST_FILTER=TestRadar make experiences-test`: 2 testes aprovados, 1,604s; elegibilidade, categoria, LIVE, período, raio, limite/ordem/truncamento, retirada/sessão, antimeridiano, limites extremos, índice; harness up/down/up das migrations no banco isolado |
| Bridge real | `make experiences-mobile-contract`: aprovado, Go 20,834s; Flutter/Dio/RadarController → Go/OpenAPI/PostGIS/S3, um caso com Radar/Home/CRUD/capas/autorização e revogação |
| Flutter | `analyze`: sem issues; 20 testes focados aprovados em Radar controller/widgets e regressões Home/navegação; formatação aplicada |
| Python | 17 testes de configuração aprovados |
| Android | APK debug atualizado gerado com configuração pública local, Gradle 30,0s; aviso condicional KGP descrito acima |
| iOS | Runner.app debug para simulador gerado com configuração local, Xcode 35,9s. Sem instalação/assinatura de distribuição |
| Permissões | APK e Info.plist do app compilado auditados conforme seção 7 |
| Higiene | `git diff --check`, `sh -n scripts/smoke.sh`, `sh -n flutterw`, aprovados; índice Git vazio |
| Ambiente local | `make mobile-local` aprovado, API saudável, `/healthz` 200, `/readyz` 200, Radar sem sessão 401 e índice `experiences_public_viewport` confirmado por leitura |

Logs de execução locais em `/private/tmp/flow-pr04-*`, temporários e fora do Git. Os widgets usam doubles somente da superfície Mapbox/localização; o bridge usa HTTP, banco e S3 reais e não renderiza MapWidget. Dados de teste ficam em `flow_experiences_test`/bucket de teste. Nenhum smoke destrutivo, fixture no banco principal, suíte Identity com interrupção de Redis, CI remota ou teste físico foi executado.

## 10. Resultados reais de runtime Mapbox

**Não observados.** O SDK e suas dependências nativas compilam para Android/iOS. Não houve token válido, carregamento comprovado de tiles/estilos, pins/clusters reais, atribuição/opt-out acionados, GPS em aparelho ou medição física de bateria/fluidez. Os testes de UI e o build não substituem essa evidência. O estado sem token e as integrações independentes foram exercitados.

## 11. Dependências externas pendentes

Token público Mapbox próprio, estilos/conta/billing aprovados e revisão operacional/privacidade do fornecedor; depois executar o [roteiro físico Android/iOS](../features/radar.md#roteiro-físico-androidios-e-gate). Colocar o token público em `apps/mobile/config/device.local.json`, recompilar pelo wrapper e usar experiências públicas criadas pelo fluxo normal. Sem necessidade de inserir segredo de download no binário.

Continuam pendências anteriores de produção: IDs/distribuição, Google/Apple/Twilio, HTTPS/origem, marca e URLs legais. O login temporário continua limitado a desenvolvimento/teste pelo backend. Não foram criados contas externas, tokens, dados fictícios de produção ou configurações legais inventadas.

## 12. Registro administrativo

[ADM-030–033](../admin-capabilities.md#radar--pr-04-adm-030033): saúde Mapbox/falhas, categorias/ícones e diagnóstico de ausência/retirada, restrições geográficas e limites/carga, configurações/métricas/auditoria futuras. Diferencia capacidades atuais (env validadas, mensagens/diagnóstico local e logs categóricos) de futuros contratos/permissões/painéis. Nenhum console ou papel/API administrativo foi criado.

## 13. Status técnico do PR-04

**Implementação e validação local independentes concluídas; fechamento integral do DoD condicionado ao runtime Mapbox com credencial válida e homologação física.** Backend real e índice foram atualizados no ambiente LAN existente, sem recriar volumes/conta. No fechamento, `main`/HEAD permaneciam `f7fcab2dd996ac95f1fb80eb04d017c896a51359`, índice vazio. Não há publicação externa, aprovação de produção ou homologação física implícita. Para rodar o app em `apps/mobile`:

```sh
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

Sem o campo `MAPBOX_PUBLIC_ACCESS_TOKEN` preenchido com token público válido, as demais funções continuam disponíveis e o Radar apresenta sua configuração pendente.

## 14. Preparação para PR-05 — Explorar e Flows

Explorar pode reutilizar catálogo, audiência/lifecycle, detalhe/capa, filtros e índices, mas requer contrato próprio de busca/paginação/cobertura; viewport truncado não representa catálogo completo. Flows necessita domínio e contratos de mídia, audiência, paginação, retenção/expiração e autorização próprios. Radar não implementa ou presume esse domínio. Participação, chat/social, P2P e pagamentos permanecem fora do escopo. Preservar cancelamento por conta, revalidação, privacidade e gates do fornecedor no próximo ciclo.
