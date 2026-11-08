# Relatório de execução — PR-03 Home Discovery

07/11/2026, America/Recife. Escopo: Home Go + contratos + Flutter + testes e operação local. Sem staging, commit, push, merge ou publicação externa.

## 1. Estado inicial

`main`, HEAD `b0fa1cde6fbc5e3b83a534da054ff90e8d5f5a0d`, árvore/índice limpos. [Inspeção inicial](pr-03-initial-review.md) registra fontes/decisão mínima. SDK fixado, configuração LAN, Personal Team, dados/volumes e acesso temporário anteriores foram preservados.

## 2. Arquivos

| Grupo | Entrega |
| --- | --- |
| Backend | `internal/experiences/home.go`, `home_test.go`, configuração/registro HTTP, `integration/home_test.go` e ajuste do rollback do harness existente |
| Persistência | `queries/home.sql`, sqlc `dbgen/home.sql.go`/`querier.go`, migration00004 somente de índice |
| Contrato/operação | OpenAPI1.2.0, .env.example/Compose com três env Home; smoke vazio acompanha a quarta migration |
| Flutter | `features/home/home_model.dart`, `home_controller.dart`, `home_page.dart`; router e método GET no ExperiencesRepository existente |
| Testes Flutter | home_controller/home_widgets, fixture home em test/support; bridge Experiences ampliado para Home; ajuste da regressão de criação ao novo destino inicial |
| Documentação | Este relatório/revisão inicial, guia Home, README raiz/mobile, schema Experiences, registro ADM e inventário de privacidade |

Nenhuma dependência/versão de SDK, capability iOS, permissão de GPS, identificador de produção, framework de estado/HTTP ou provedor foi acrescentado.

## 3. Endpoint e contrato

Novo `GET /v1/home` autenticado; **32 operações** no OpenAPI1.2.0. Experiência/ID/versão/capa e detalhes PR-02 preservados. Resposta tem relógio/frescor/configuração efetivos, localidade opcional, catálogo e seis seções com regra, disponibilidade e itens Experience/category_name/distance_m. Query e resposta limitadas; até41 cards, categoria contextual habilitada, raio1..100km, JSON até2MiB, timeout2s; sem cursores ou totais artificiais. Sem localidade: geral + nearby locality_required. Erros usam envelope existente; falha de dependência é global, sem falso vazio.

## 4. Regras

PUBLIC/PUBLISHED/VISIBLE e fim futuro, pela visão central existente. Destaque: próximo início futuro; agora: início <= as_of < fim; breve: futuro dentro da janela operacional (48h default); perto: PostGIS/distância; contextual: região/categoria escolhidas e agenda/recência; adicional: criação recente. Empate por ID; até duas ocorrências por experiência. Ordens, prioridades, deduplicação e limites completos no [guia](../features/home-discovery.md). Sem editorial/patrocínio/preferência persistida/afinidade inventados. Índices de agenda/categoria/GiST e novo índice parcial de recência; sem N+1/cache/consumidor assíncrono.

## 5. Flutter

Início em `/app`, saudação/Flow/região, hero e rails com capas/agenda/status reais, categorias contextuais, atalhos de seção, atualização e estados loading/erro/vazio. Oculta seções vazias; região é opcional. Claro/escuro, texto ampliado, teclado e movimento reduzido suportados pelos componentes/tokens Flow e Material3. Coordenação Riverpod cancela buscas obsoletas, usa Identity/Dio centrais, respeita Retry-After, limpa dados por conta e suspende no background. Revalida no retorno/resume e fronteira temporal/60s nominal, usando intervalos do relógio do servidor. Rolagem vertical é restaurada conforme o conteúdo disponível.

## 6. Integração com detalhes

Card abre o ExperienceDetailPage existente pelo ID; autorização e capa são revalidadas. Gestão/criação continuam em `/experiences`. Não há ações fictícias de participar/curtir/seguir, notificações sem rota ou contagens sociais. Falha de mídia exibe placeholder/retry e revalida uma vez por ID/versão/capa, sem loop ou armazenamento de URLs assinadas.

## 7. Segurança e privacidade

PRIVATE, UNLISTED, drafts, cancelados, arquivados, retidos e encerrados não entram. Centro manual arredondado a duas casas, distância100m, rótulo local não enviado; raio informado ou default real da API. Sem GPS/permissão, inferência por telefone/IP, geocoding falso, trail, analytics ou persistência de região. Sessão/restrição/troca de conta descartam dados e operações. Sem cache de composição; não há push de moderação e alterações remotas dependem de revalidação. Provas/segredos/queries não entram nos logs. [Inventário](../privacy/data-governance.md) atualizado.

## 8. Validação efetivamente executada

| Verificação | Resultado observado |
| --- | --- |
| Go | gofmt sem pendências; go test ./internal/experiences/... aprovado; go vet ./internal/experiences/... ./cmd/api aprovado |
| Contratos | OpenAPI1.2.0 válido,32 operações; schemas events/realtime/lifecycle válidos; sqlc regenerado |
| PostGIS real | Quatro testes Home aprovados,2,065s: elegibilidade/retirada/sessão, limites/empates/índices, fronteiras temporais exatas, catálogo até100; harness up/down/up00004/00003 preservando Identity |
| Flutter | analyze sem issues;27 testes focados aprovados;48 arquivos formatados/zero mudanças |
| Bridge real | make experiences-mobile-contract aprovado: Go18,109s,Flutter um caso; Home/região/cancelamento/visibilidade/revogação mais CRUD/capa S3/detalhes existentes e validação OpenAPI |
| Android | APK debug gerado,45,6s; configuração pública local existente |
| iOS | Runner.app de simulador gerado,256,0s; assinatura pessoal/configuração nativa preservadas |
| Higiene | git diff --check e sh -n scripts/smoke.sh aprovados; script acompanha a quarta migration |
| Ambiente local | make mobile-local final aprovado; healthz200/readyz200; Home sem sessão401; índice experiences_public_recent confirmado por leitura no banco principal |

Sem execução de smoke destrutivo no banco principal, suíte global repetida, CI remota, instalação deste ciclo no iPhone ou homologação física/provedores. O teste do índice força elegibilidade de plano, não mede carga real.

## 9. Pendências externas

Google/Apple/Twilio e distribuição definitivos, HTTPS/origem e operação de produção, marca/URLs legais, Mapbox/geocoding e homologação física continuam pendentes. Login local temporário permanece real no backend de desenvolvimento. Seleção manual de região é funcional; busca por nome/mapa não foi implementada. Não foram preenchidas seções com fixtures de produção. Testes usam exclusivamente dados sintéticos em destinos isolados.

## 10. Administração

[ADM-027–029](../admin-capabilities.md): critérios/configuração de seções/ordenação e futura curadoria auditada, diagnóstico de ausência/limites/retirada, falhas e observabilidade operacional. Apenas env validadas e status/duração/IDs HTTP/probes estão disponíveis agora. Não há console, papel/API admin, métrica de conversão ou plataforma de anúncios.

## 11. Status

**PR-03 tecnicamente concluído no escopo local**, com os testes e builds acima. API de desenvolvimento recompilada e índice aplicado por make mobile-local, preservando conta/volumes. Probes/índice conferidos após a atualização. No fechamento de07/11, HEAD permanecia b0fa1cde6fbc5e3b83a534da054ff90e8d5f5a0d;33 arquivos novos/alterados, índice Git vazio. Não há aprovação de produção ou teste físico implícitos. Nenhuma alteração de Git remoto foi executada pelo agente.

### Retomada — 08/11/2026

Na retomada, `main` já continha a entrega no commit `f7fcab2dd996ac95f1fb80eb04d017c896a51359` (`PR-03 Parcial`), com árvore/índice limpos e os33 arquivos incorporados. Esse commit já existia; não foi criado nesta execução. O código corresponde à implementação validada acima. Os logs temporários anteriores não estavam mais presentes; os resultados acima registram a execução de07/11 e não são apresentados como testes repetidos nesta retomada.

Docker Desktop estava desligado e a API indisponível. Docker foi iniciado e `make mobile-local` concluiu, mantendo os volumes, a configuração de acesso temporário e as configurações nativas. Conferência por leitura após a subida: `/healthz`200, `/readyz`200, `/v1/home` sem sessão401, índice `experiences_public_recent` presente. Apenas este relatório foi atualizado no código versionado durante a retomada; nenhuma nova implementação, staging, commit, push, merge, publicação externa ou instalação física foi realizada. Para atualizar o iPhone, executar em `apps/mobile`: `../../flutterw run --release --dart-define-from-file=config/device.local.json`.

## 12. Preparação exata para PR-04 — Radar

Reutilizar audiência/lifecycle, GET paginado PostGIS `/v1/experiences`, IDs/detalhes/capas e seleção aproximada. Definir viewport/limites/frescor e acessibilidade/atribuição; aprovar/configurar fornecedor de mapas/geocoding e seus dados; eventual GPS requer finalidade/consentimento antes da permissão, inventário atualizado e teste físico. Preservar cancelamento por região/conta e revalidação. Não usar os candidatos/deduplicação limitados da Home como listagem geográfica completa. Não entregar Radar, Explore, Flows, Social ou Participation por implicação deste ciclo.
