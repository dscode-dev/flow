# Início / Home Discovery — PR-03

PR-04 acrescentou [Radar](radar.md) à navegação real, preservando a composição abaixo. A seção de preparação ao final registra a fronteira original do PR-03; configuração/gates atuais do Mapbox estão no guia Radar.

OpenAPI **1.2.0**, `GET /v1/home`, sessão Flow ativa, mesmo middleware/limite de origem de Experiences. Entrada Flutter `/app`; gestão em `/experiences`; cards abrem `/experiences/{id}` existente. Não há novas dependências, cliente HTTP, autenticação ou papel administrativo.

## Contrato e limites

Uma chamada compõe seis seções e o catálogo habilitado (até100 entradas em sort_order/id). Dois statements constantes: catálogo e candidatos; o segundo contém seis branches limitados sobre `experiences.discovery`, no mesmo snapshot. Não faz GET por experiência, ranking externo, contagem global ou busca de perfil. Capas continuam sendo leituras HTTP autenticadas e autorizadas independentemente. Sem cursor/total: é uma seleção limitada, não uma listagem completa.

`limit` opcional entre1 e `HOME_SECTION_LIMIT` (default6, máximo8); highlights até1; total até1+5*limit, máximo41 cards. Query até2048 bytes, JSON serializado até2MiB (excesso responde503, sem resposta parcial), timeout de consulta2s. Categorias além das primeiras100 não são escolhas desta composição. Erros padrão400/401/403/429/503; 429 e Retry-After passam pelo coordenador existente. Categoria indisponível pode ser removida pelo botão “Limpar categoria”, inclusive após erro. Indisponibilidade de banco/catálogo é erro global; seção `empty` nunca significa falha de dependência.

Parâmetros: `latitude`/`longitude` juntos; `radius_m` opcional somente com o par (1000..100000m), default `HOME_RADIUS_M=25000`. Servidor arredonda centro a duas casas decimais antes do PostGIS. Distância geodésica da seção nearby é arredondada a100m, relativa ao centro escolhido, não ao aparelho. `category_id` habilitada opcional refina **somente contextual**. Duplicados, desconhecidos, vazios, não finitos, limites inválidos e query malformada recebem400. Resposta informa `as_of`, `refresh_at`, `soon_hours`, `default_radius_m`, limite efetivo, localidade normalizada ou null, categoria ou null, catálogo e seções. Identidade da experiência/versão/capa preserva o contrato PR-02.

## Elegibilidade e ordenação

Todas as seções exigem PUBLIC + PUBLISHED + VISIBLE + ends_at > as_of. Reutilizam a visão atual; PRIVATE/UNLISTED/drafts/histórico/WITHHELD nunca entram, mesmo para o criador. Restrição de nova publicação não suspende automaticamente publicações anteriores; retirada exige o mecanismo de moderação do domínio, conforme ADM-016/020. Não alterar essa política silenciosamente.

| ID / UI | Candidatos e ordem antes da deduplicação |
| --- | --- |
| highlights / Destaques | Próximo início futuro, starts_at/id ASC, até1; agenda geral, sem seleção editorial ou patrocínio |
| live / Acontecendo agora | starts_at <= as_of < ends_at, starts_at/id DESC; agenda geral |
| soon / Começa em breve | as_of < starts_at <= as_of + HOME_SOON_HOURS; starts_at/id ASC; default48h, configurável1..168h; agenda geral |
| nearby / Perto de você | ST_DWithin no raio selecionado, distância ASC, starts_at/id ASC; sem centro: locality_required |
| contextual / Para você | Região/raio e categoria explicitamente escolhidos, quando fornecidos; starts_at ASC, created_at DESC, id ASC. Sem escolhas: agenda geral, identificação honesta “Descoberta contextual” |
| recent / Em destaque | created_at/id DESC; experiências elegíveis criadas mais recentemente, agenda geral |

Sem afinidade, histórico, amizades, participação, popularidade, avaliação, IA ou preferência persistida. Não há pontuação editorial escondida. Até duas aparições por ID, alocadas na ordem acima; se os candidatos limitados já atingiram duas, são removidos, sem backfill/query extra. Isso pode esvaziar seções com poucas experiências. UI oculta vazios, mostra convite para escolher região em nearby e vazio geral real quando não há conteúdo. Seleção de região não restringe as seções explicitamente identificadas como agenda geral.

Índices de agenda/categoria/GiST existentes são aproveitados; migration00004 acrescenta apenas índice parcial global de recência. Não muda agregado, lifecycle, outbox, tabelas de conteúdo ou migrations aplicadas. `NOT MATERIALIZED` permite planos independentes de cada branch. Limite de tempo protege consultas densas; teste de uso possível de índice não é benchmark/capacidade de produção.

## Frescor, sessão e mídia

Sem Redis/cache de composição: `Cache-Control: no-store`. Alterações confirmadas entram na próxima consulta; não há janela assíncrona de indexação. `phase` e seleção usam o mesmo `as_of` do servidor. `refresh_at` é o mínimo de as_of+60s e próximo início/fim dos itens retornados. Flutter usa diferença de instantes do servidor menos tempo de chamada, com piso1s; não depende do relógio do aparelho. Pull-to-refresh, toolbar, retorno de detalhe/gestão e resume também revalidam. Não há push de moderação; uma alteração remota pode permanecer visível até a próxima revalidação, no máximo a janela nominal60s com rede disponível. Detalhe e capa autorizam novamente.

Controller Riverpod/ValueNotifier usa ExperiencesRepository/Dio e AuthController.authorized centrais. Single-flight, cancelamento e geração impedem resposta de localidade anterior; erro limpa cards antigos. Saída/restrição/troca de conta limpam cards, filtros, requests e timers. Background/navegação suspendem timers e removem conteúdo antes de revalidar; filtros continuam em memória para a mesma conta. Rolagem vertical é restaurada quando o conteúdo atualizado permite. Sem persistência offline de cards ou região.

ExperienceCover reutiliza pixels em memória, cancela/dispose em background/conta e não usa cache global/disco/signed GET. Falha403/404 provoca uma revalidação da Home por ID/versão/media_id; sem loop se o servidor ainda referencia capa indisponível. Placeholder/retry de mídia não inventam foto nem impedem abrir detalhes. Cards exibem título, categoria, agenda IANA, venue, fase autoritativa, distância aproximada quando disponível e ingresso externo quando o campo existe. Não oferecem RSVP/like/follow. Layout segue tokens/componentes Flow, claro/escuro, texto ampliado, navegação de teclado e movimento reduzido para os atalhos de seção.

## Região sem GPS

Nome livre de cidade/região é **rótulo local**, não geocoding: a pessoa informa um centro aproximado e raio. Formulário explica a finalidade e ausência do buscador de cidades. Nenhuma cidade/posição é inferida do telefone, IP ou endereço, nenhum catálogo geográfico inventado. Decimal brasileiro é aceito; centro normalizado a duas casas (~1km em latitude, variável na longitude), raio1..100km. Default vem da API; se indisponível, a pessoa deve informar o raio. Pode continuar sem localidade e descobrir pela agenda geral.

Nome/ponto/categoria só vivem em memória da sessão; nome não é enviado. Sem GPS, permissão nativa, rastreamento, localização em background ou histórico. Query transita na API; middleware existente omite URL/query e bodies dos logs/spans. Nenhum analytics novo. Servidor não grava parâmetros de descoberta. HTTPS continua obrigatório em produção; HTTP é exceção local já existente.

## Validação e operação

`FLOW_EXPERIENCES_TEST_FILTER=TestHome make experiences-test`: banco `flow_experiences_test` e bucket isolado, OpenAPI, audiência/estado, fronteiras start/end/janela em microssegundos, distância/centro, região, limites, deduplicação, empate e retirada. Harness valida rollback de00004/00003 até versão2, preservando Identity/outbox/PostGIS; não toca dados principais.

`make experiences-mobile-contract`: bridge existente agora também prova HomeController → Dio/Identity → Go/OpenAPI/PostGIS, mudança de região, retorno ao detalhe/capa S3, ausência após cancelamento, exclusão UNLISTED/PRIVATE e revogação de sessão. Fixtures só no binário de teste. Testes Flutter focados cobrem loading/vazio/rede/retry, concorrência, região, logout, navegação, capa negada, timer/resume, 320px/200%/temas/teclado. Builds não comprovam interação física.

Configuração de seções é operacional por env/deploy local, sem endpoint admin. Ver ADM-027–029. Sem métricas específicas de recomendações: só status/duração/request_id/trace_id HTTP e probes existentes. Índices/timeout/caps não substituem medição de carga real. `make mobile-local` atualiza somente a stack de desenvolvimento; `make smoke` continua exclusivo de banco vazio e não deve ser usado com a conta temporária existente.

## Limites e PR-04

Busca por nome de cidade, mapa e GPS dependem de fornecedor/configuração aprovados; não foram simulados. Identity externo, HTTPS/infra produtiva, identidade visual e URLs legais continuam pendentes, assim como homologação física. Região manual é funcional e temporária, não prova Mapbox.

Radar poderá consumir filtro PostGIS/paginação de `/v1/experiences`, IDs/detalhes/capas existentes e a escolha aproximada de região. Precisará definir contrato de viewport/limites/frescor, aprovação/configuração do mapa/geocoding, acessibilidade/atribuição e eventual consentimento antes de GPS, com atualização do inventário e testes físicos. Não reutilizar o limite/deduplicação da Home como listagem completa. Social/Participation/Flows/Notifications/preferências/patrocínios exigirão contratos e sinais reais próprios; extensões da composição devem versionar/adicionar IDs/ordens conscientemente, preservando Experiences e a política de audiência. Nenhum desses módulos foi iniciado aqui.
