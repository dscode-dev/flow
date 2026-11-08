# Radar — PR-04

Radar usa `GET /v1/radar/experiences` no mesmo módulo Experiences/Identity e `mapbox_maps_flutter` oficial3.34.2. Flutter3.47.8/Dart3.13.7 preservados; geolocator14.1.2 resolvido para leitura opcional cancelável. Não há outro banco, framework de estado/HTTP ou serviço de descoberta. Fonte da elegibilidade continua `experiences.discovery`. OpenAPI1.3.0,33 operações.

## Gate de configuração real

Em 08/11/2026, após a implementação inicial sem credenciais, o proprietário informou que gerou seu token Mapbox. Falta inseri-lo na configuração local e recompilar para validar o runtime. Sem token público sintaticamente aceitável, Radar mostra configuração indisponível e não constrói MapWidget nem consulta uma área inventada. A Home e a gestão continuam funcionando. Compilação, testes com doubles de plataforma e integração HTTP real não comprovam tiles/pins/clusters renderizados pelo SDK; esse gate continua pendente até execução com token válido e homologação Android/iOS.

1. Obter uma conta/token público próprio seguindo [Mapbox Access Tokens](https://docs.mapbox.com/help/dive-deeper/access-tokens/). Usar somente permissões públicas necessárias à leitura de mapas/estilos/fontes; não adicionar permissões administrativas. Conta/billing/fornecedor exigem aprovação do proprietário.
2. Em `apps/mobile/config/device.local.json` ou outro arquivo público `.local.json` ignorado, adicionar `MAPBOX_PUBLIC_ACCESS_TOKEN` com o token `pk...`. Nunca inserir `sk...`, token de download/registry, senha ou segredo em Dart defines/Info.plist/Manifest. O preflight recusa esses casos sem imprimir valores.
3. O template `auth.public.example.json` documenta também `MAPBOX_STYLE_LIGHT`, `MAPBOX_STYLE_DARK`, `RADAR_THEME` (`system/light/dark`) e `RADAR_INITIAL_LATITUDE`, `RADAR_INITIAL_LONGITUDE`, `RADAR_INITIAL_ZOOM` (strings). Styles aceitam URIs `mapbox://styles/owner/id`, defaults oficiais light-v11/dark-v11. Sem contexto/configuração específica, centro0/0 e zoom2 mostram a visão geral e solicitam aproximação; não inferimos cidade por telefone/IP.
4. Da raiz, `make mobile-local`; em `apps/mobile`, `../../flutterw run --release --dart-define-from-file=config/device.local.json`. O helper preserva campos Mapbox já preenchidos. Token público é incorporado ao binário, não deve ser tratado como segredo; manter fora do Git e restringir escopos/uso conforme o fornecedor permite. Troca de token/configuração requer recompilar.

### Inserir o token já gerado

Abra `apps/mobile/config/device.local.json` e substitua apenas o valor vazio de `MAPBOX_PUBLIC_ACCESS_TOKEN` pelo token público completo que começa com `pk.`. Preserve os outros campos, especialmente `API_BASE_URL` e a configuração de autenticação. O helper local agora inclui os campos Radar em arquivos novos e preserva token/estilos ao atualizar a rede. O preflight usa a mesma regra de formato do app, sem imprimir o valor.

```json
"MAPBOX_PUBLIC_ACCESS_TOKEN": "pk.COLE_AQUI_SEU_TOKEN_PUBLICO_COMPLETO"
```

Esse trecho representa um campo do JSON existente, não o arquivo inteiro. Os estilos claro/escuro e tema já têm defaults; não é necessário alterar Manifest, Info.plist ou backend para inserir esse token. Interrompa a execução anterior do Flutter e faça uma compilação nova; hot reload/restart não altera os dart-defines incorporados:

```sh
# Na raiz do repositório, se precisar iniciar/atualizar a API e o endereço LAN:
make mobile-local
cd apps/mobile
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

Mac e iPhone precisam estar na mesma rede para a API local; o mapa também exige acesso aos serviços Mapbox. Entre no app, abra Radar e aproxime a região desejada ou use Região. O centro inicial padrão é uma visão geral; não implica localização GPS. Mapa carregado e nenhuma experiência na área são estados distintos. Siga o roteiro físico abaixo para confirmar pins/clusters com dados públicos reais.

[Instalação/requisitos oficiais](https://docs.mapbox.com/flutter/maps/guides/install/), [SDK estável](https://pub.dev/packages/mapbox_maps_flutter), [migração v3](https://docs.mapbox.com/flutter/maps/guides/migrate-to-v3/). Não foi solicitado/provisionado token secreto de download. A atribuição nativa permanece habilitada e clicável, com wordmark e botãoⓘ no topo do mapa para não serem cobertos pela prévia. Esse controle mantém créditos e opt-out de telemetria conforme [Mapbox](https://docs.mapbox.com/flutter/maps/guides/). Há explicação no botão “Sobre o Radar”; não há implementação própria que simule o opt-out. Verificar funcionamento real do controle no gate físico.

## API, filtros e custo

Sessão Flow ativa; middleware e limites de origem existentes. Query estrita até2048 bytes: `bbox=west,south,east,north` e `zoom` obrigatórios. Bounds inclusivos; west>east divide o envelope em duas partes no antimeridiano; west=east é inválido, não significa mundo inteiro. Latitude suportada pela projeção Mercator é±85.051129; longitude±180; zoom0..22. Viewport amplo/zoom insuficiente retorna400 `radar_area_too_large`, sem efetuar a consulta espacial. Demais valores inválidos, duplicados, vazios ou desconhecidos recebem400 `invalid_request`.

| Parâmetro | Regra |
| --- | --- |
| category_id | Categoria real opcional; desconhecida resulta vazio, sem inferência privada |
| phase | LIVE ou UPCOMING; derivada em SQL usando o mesmo as_of |
| from/until | Ambos UTC; início menor que fim; até31 dias transcorridos; sobreposição starts_at < until e ends_at > from. UI seleciona dias no fuso do aparelho e envia UTC; fim exclusivo no dia seguinte |
| latitude/longitude/radius_m | Trio opcional; centro arredondado a2 casas antes de sair do Flutter e novamente no Go; raio1000..100000m. Referência fixa escolhida ao aplicar, não rastreia a posição/câmera continuamente |
| limit | Default/teto operacional, nunca maior que200; não é paginação completa |

Configuração operacional: `RADAR_RESULT_LIMIT=100` (1..200), `RADAR_MIN_ZOOM=4` (1..12), `RADAR_MAX_SPAN_DEGREES=30` (1..60, ambos eixos). Query tem contexto2s e resposta JSON até1MiB. Cliente evita os limites padrão4/30 antes de solicitar e aprende os limites efetivos na primeira resposta aceita; servidor sempre é autoridade. Ao reduzir a política operacional, clientes podem receber o aviso de aproximação até usar uma área aceita. Não há Redis/cache adicional.

Consulta sqlc única sobre a visão existente, joins de categoria no mesmo statement, filtro retangular PostGIS e ordenação starts_at/id ASC. Busca limit+1, retorna no máximo limit e `truncated`; não retorna total, contagem de privados ou cluster do banco. Exige PUBLIC/PUBLISHED/VISIBLE e ends_at>as_of, inclusive para o criador. DRAFT/UNLISTED/PRIVATE/CANCELLED/ARCHIVED/WITHHELD/encerradas nunca entram. Restrição de nova publicação não retira anteriores automaticamente; moderação de conteúdo mantém ADM-016/020. Sem N+1, indexador assíncrono ou reescrita de lifecycle.

Migration00005 acrescenta somente GiST parcial de `(point::geometry)`, necessário ao envelope lon/lat retangular; o índice geography existente permanece para ST_DWithin. Envelope de geography teria bordas geodésicas, inadequadas ao retângulo visível. Up/down dos índices e schemas são testados somente no banco isolado. `make smoke` continua exclusivo de banco vazio; agora acompanha as cinco migrations e não deve ser executado na conta local existente.

Resposta compacta: as_of/valid_until, limite/zoom/amplitude efetivos, truncated e marcadores com ID/versão/categoria/nome/ponto autorizados, título/venue/agenda/fuso/fase, referência de capa e indicador real de ingresso externo. Sem descrição completa, dados Identity privados, participantes, patrocínio ou popularidade. A prévia revalida GET Experience; capa usa leitura autorizada existente, nunca signed GET permanente. Sem sucesso parcial falso em indisponibilidade da API.

## Câmera, renderização e estado

Rota protegida `/radar`, acesso pela Home; somente Início/Radar/Minhas experiências são destinos funcionais. Não existia rota Mapa a renomear; destinos futuros não foram simulados. Câmera em memória da conta, inicializada pela região Home quando disponível. Gestos/zoom nativos, controles de zoom, região manual e centralização explícita. Detalhes usam o router existente e retorno revalida preservando a câmera. MapWidget permanece estável, separado das reconstruções de estado/controles; reload explícito recria o limite nativo para recuperação.

Eventos de câmera invalidam/cancelam requisições uma vez por movimento; onMapIdle obtém o envelope e agenda350ms de debounce. Chaves por bounds/filtros/zoom deduplicam equivalentes; geração impede resposta fora de ordem. Viewport usa precisão suficiente aos maiores zooms; isso é área escolhida, não uma trilha GPS. Limpar filtros/retry/atualização manual são explícitos. Sem polling contínuo: valid_until é o menor entre as_of+60s e próxima fronteira temporal retornada; um timer remove pins vencidos e oferece atualização. Retorno/resume consultam novamente. Mudança de conta/saída/restrição remove câmera, filtros, seleção, requests, timers e fonte. Background suspende; diálogo de permissão inativo não é confundido com execução em background.

Fonte GeoJSON local limitada aos itens recebidos, clustering nativo radius48/maxZoom16, circle/symbol style layers e ícones Material por categoria atual, fallback de categoria futura. IDs de experiências permanecem propriedades estáveis; IDs numéricos da coleção são apenas identificadores de renderização. Clusters contam somente a fonte recebida; aviso de truncamento permanece visível e a lista acessível usa os mesmos itens. Não há widget por pin, pulso permanente, afinidade ou contagem fabricada. Cor/tamanho, borda LIVE e anel de seleção diferenciam estados; transições de estilo/câmera são discretas/sem animação custosa. Estilos e imagens são reinstalados após troca claro/escuro, com descarte de operações de estilo obsoletas.

Seleção reconsulta a área antes de abrir a prévia, que busca o detalhe real e mostra capa/agenda/categoria/venue permitidos. Conteúdo que deixou a descoberta não abre uma prévia antiga. Cancelamento/histórico/redaction são tratados;403/404 de capa revalida o detalhe uma vez por versão/ref, sem loop. A ação implementada é “Ver detalhes”; não há RSVP/like/chat/share fictício. Ao expirar a seleção ou perder a sessão, a prévia é encerrada. Lista da área complementa acessibilidade do mapa; sheets usam scroll/área segura, temas/texto ampliado e mensagens genéricas sem payload de SDK.

## Localização e terceiros

Nenhuma permissão é solicitada ao abrir Radar. Somente a ação “Usar minha região aproximada”, após explicação/aceite contextual, verifica serviço/permissão e pede acesso durante o uso. Android declara somente COARSE; FINE/BACKGROUND/FOREGROUND_SERVICE_LOCATION são removidas no merge. iOS só NSLocationWhenInUseUsageDescription; wrapper exporta BYPASS_PERMISSION_LOCATION_ALWAYS=1 para o geolocator_apple SPM, conforme [plugin oficial](https://pub.dev/packages/geolocator). Sem permissionamento Always nem foreground service de localização.

Uma assinatura cancelável aguarda somente o primeiro fix de baixa precisão, com timeout12s; cancela depois do fix, timeout, background, troca de conta ou dispose. Não há stream persistente, puck Mapbox ativo, compartilhamento social, histórico ou inferência por IP. Ponto é arredondado a2 casas antes de centralizar/consultar; precisão/altitude/velocidade/heading não são enviados à API. Negação, restrição, revogação, timeout e serviço desativado não impedem descoberta por câmera/região manual.

Mapbox recebe token público, IP/informações técnicas e recursos solicitados da área exibida; seu cache nativo de tiles/estilos pode persistir recursos geográficos e não equivale a um histórico explícito mantido pelo Flow. Telemetria e sua preferência são geridas pelo SDK/controle de atribuição. Não prometer anonimato irreversível ou ausência de dados do fornecedor; aprovação contratual, avisos legais, retenção/região/menores/billing e revisão de telemetria permanecem com o proprietário. [Inventário](../privacy/data-governance.md) atualizado. App não registra token, bounds ou coordenadas em logs; nunca loga mensagem bruta de erro do SDK. Backend só status/duração/request_id e contagem/truncamento de candidatos públicos.

## Performance e evidências

GPU/SDK nativo, GeoJSON limitado, atualização de fonte somente ao mudar conteúdo, seleção por layer filter, atualizações de estilo serializadas com geração, sem widgets por marcador, dedup/debounce/cancelamento e recursos encerrados no dispose. Cache do SDK permanece padrão, sem downloads offline promovidos pelo Flow. Diagnósticos locais em memória: duração HTTP, itens, cancelamentos/obsoletas, erros de mapa e proxy fonte→próximo frame FULL para dados não vazios. Não é prova de pins visíveis; validar com SDK/token reais. Painel/analytics/benchmark de carga não foram criados.

Testes: Go unitário de entrada/configuração; PostGIS real em flow_experiences_test cobre elegibilidade, retângulos, antimeridiano, raio, categoria, período, ordenação/limite/truncamento/retirada/sessão. Bridge Experiences existente inclui RadarController/Dio → Go/OpenAPI/PostGIS, junto de Home/CRUD/capas S3 e revogação. Testes Flutter de UI usam double **apenas da superfície Mapbox nativa e localização**; não são evidência de runtime de MapWidget. Ausência de token é testada sem construir sequer esse limite. Casos incluem cancelamento, debounce, expiry sem polling, permissão negada, filtros, prévia/detalhe/retorno, estado vazio, claro/escuro/320px/200% e limpeza de conta. Evidências finais/builds no [relatório](../architecture/pr-04-completion-report.md).

## Roteiro físico Android/iOS e gate

Com token próprio/estilos aprovados, API alcançável e experiências públicas reais criadas pelo fluxo normal:

1. Abrir sem GPS: tiles reais, zoom/gestos/câmera, wordmark/ⓘ legíveis; verificar créditos e opt-out do SDK. Validar token inválido, estilo inválido, perda de tiles/rede e reload; sem mapa estático de fallback.
2. Aproximar uma região com conteúdo, selecionar categorias/período/LIVE/raio, limpar, testar vazio/limite e conferir que cluster conta apenas os pins recebidos. Pan distante/antimeridiano; respostas antigas não devem substituir a área atual.
3. Abrir pin/prévia/capa e detalhes, voltar com câmera preservada. Cancelar/retirar outra experiência e revalidar; testar404/403/revogação, expiração de pins60s e atualização manual.
4. Acionar localização: explicar, negar, autorizar aproximada, revogar no OS, desativar serviço e ir ao background durante aquisição. Confirmar cancelamento/ausência de indicador persistente e descoberta sem GPS. Não coletar trilha para comprovar o teste.
5. Alternar claro/escuro repetidamente, texto ampliado, leitor de tela/lista e telas menores/landscape; verificar atribuição não coberta pela prévia. Interromper/retomar e testar logout/troca de conta.
6. Observar fluidez/bateria/GPU em aparelho de referência com fonte próxima do limite; correlacionar diagnósticos por categoria/request_id sem coordenadas/tokens. Registrar versão OS/SDK/artefato/resultado; não afirmar benchmark ou homologação com base só no build.

## Próximo ciclo

Explorar poderá reutilizar catálogo, paginação pública, Experience/detail/cover e os filtros espaciais/temporais, com contrato próprio para pesquisa e cobertura; viewport limitado/truncado não é um catálogo completo. Flows exige domínio/contratos de mídia, audiência, paginação e expiração próprios, mantendo autorização de Experiences. Social/Participation/Chat/pagamentos não foram implementados. Ver ADM-030–033 para necessidades operacionais futuras.
