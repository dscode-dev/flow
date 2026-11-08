# Experiences no Flutter — PR-02.B

Cliente real do [OpenAPI 1.1.0](../../contracts/openapi/flow.yaml) e das [regras PR-02.A](experiences.md). Não há CRUD local, entrada sem autenticação, RSVP, pagamento, feed ou Radar.

## Navegação e componentes reutilizáveis

| Destino interno | Uso |
| --- | --- |
| `/app` e `/experiences` | Minhas experiências, cursor e filtro de estado |
| `/experiences/new` | Criação: identidade, quando, onde, acesso, revisão |
| `/experiences/{UUID}/edit` | Retomar rascunho ou corrigir publicação elegível |
| `/experiences/{UUID}` | Detalhes, revisão/publicação e gestão de lifecycle |

Módulos futuros podem abrir `/experiences/{UUID}` com go_router, sem bearer, coordenadas ou URL de retorno. O guard aceita caminhos internos reconhecidos e UUID; exige sessão/onboarding e retém destino seguro sem query/fragmento. Universal Links/App Links ainda dependem de domínio/IDs aprovados. PUBLIC/UNLISTED continuam autenticados; UUID não concede acesso a PRIVATE.

`ExperienceSummary`, `ExperienceCover` e `ExperienceStatusBadge`, em `features/experiences/presentation/widgets`, são reutilizáveis. Resumo respeita `details_redacted`; capa exige modelo autorizado, sem URL arbitrária. Organizador é o próprio nome já autorizado ou referência opaca da API. Sem endpoint fictício de perfil, total ou engajamento.

## Arquitetura e sessão

`domain`: modelos, enums com fallback, IANA e fronteira de busca. `data`: repository Dio e upload. `application`: coordenadores. `presentation`: páginas/componentes Flow. Riverpod controla escopo; ValueNotifier segue a convenção existente do AuthController.

JSON e capa reutilizam `httpClientProvider` e `AuthController.authorized`. Só GET pode repetir após refresh central. Escritas 401 não repetem automaticamente; onboarding é revalidado pelo Identity. Saída/restrição/mudança de conta cancelam requests e limpam dados e mídia. S3 usa transporte separado, sem Authorization/cookies/interceptores da API, por exigência contratual. `Retry-After` bloqueia novas chamadas de rede durante o prazo.

Lista cancela requests anteriores, ignora respostas obsoletas, deduplica IDs e reinicia cursor ao filtrar/recarregar. Erro da próxima página conserva itens confirmados; autorização negada remove dados. Detalhes recarregam ao retomar o app. Sem banco offline.

## Gravações e lifecycle

Salvar é explícito. POST congela documento e chave UUID; timeout mantém a intenção e bloqueia edição até reconciliação. Toques simultâneos compartilham operação. Recebido o ID, retries buscam esse ID; GET após replay resolve o snapshot original. Janela24h não é renovada automaticamente: conferir lista antes de criar outra intenção. Sair com conteúdo não salvo pede confirmação; encerramento do processo perde formulário/chave em memória, sem afirmar recuperação offline.

PUT envia os treze campos, inclusive null para limpar. ETag forte e aspas são preservados; versão int64 usa BigInt no modelo nativo. 412 conserva edição e não troca ETag silenciosamente. Comparação busca versão atual; confirmação explícita descarta a edição para carregar essa versão e editar novamente. Não há merge automático de campos protegidos.

PUBLIC/UNLISTED mostram a consequência de divulgar local antes da confirmação de publicação. Ações da UI são sugestões por autoria/estado/fase, não um novo contrato de permissões. Go autoriza e valida todos os comandos. Publicadas preservam agenda, local, categoria, capacidade e audiência no PUT. Cancelar/arquivar exigem confirmação; estado só muda após resposta do servidor.

## Agenda e local

`timezone` usa base IANA embarcada, independente do aparelho. Fuso escolhido explicitamente, instantes UTC; conversão enumera offsets da base e faz round-trip. Lacuna DST é recusada; repetição exige escolha de instante. Testes cobrem Nova York, meia hora em Lord Howe, dia suprimido em Apia e meia-noite em Recife. Editar texto conserva instantes; trocar fuso mantém instantes e informa a mudança de apresentação.

Mapbox não possui configuração/provedor aprovado no repositório. `LocationSearch` é fronteira substituível desativada, sem resultados falsos. Venue/endereço e coordenadas podem ser informados e conferidos manualmente, inclusive em outra cidade. Sem posição do usuário, permissão GPS, mapa fictício ou background location. Busca/mapa reais exigem configuração e homologação próprias.

## Capas e ticket

Galeria via image_picker, sem câmera/vídeo/metadados completos. Android recupera seleção interrompida somente com confirmação explícita no editor; não associa imagem automaticamente a outra conta. Bytes/dimensões são conferidos antes da decodificação completa: JPEG/PNG, até5MiB,4096px/lado,12MP. Isolate aplica orientação EXIF e remove metadados; valida novamente os bytes finais antes de assinar seu tamanho/MIME exatos.

Iniciação idempotente → multipart S3 com todos os fields intactos e file por último → confirmação READY do mesmo media_id → POST/PUT condicionado → leitura autorizada. A UI distingue enviada, verificada e associada. Retry de confirmação não reenvia bytes já aceitos; expiração exige nova autorização explícita. Nunca reescreve host/assinatura ou envia bearer Flow ao storage.

PR-02.A não emite signed GET: só POST S3 expira. Capa é endpoint autenticado no-store, sem redirect. Widget mantém imagem decodificada própria, sem ImageProvider/cache global/disco; descarta ao sair, perder acesso ou ir para background. Falha oferece nova leitura autorizada, sem cópia privada antiga. Ticket HTTPS abre em aplicativo externo após aviso, sem WebView, preview, checkout ou garantia de pagamento.

## Ambiente e validação

Raiz: `make mobile-local`; mobile: `../../flutterw run --release --dart-define-from-file=config/device.local.json`. Overlay libera apenas API e S3 privado no IPv4 detectado, preservando loopback das demais dependências e volumes. Backend configura o endpoint assinado alcançável. Mesma rede Mac/iPhone e permissão Rede Local são necessárias. Produção exige HTTPS; storage HTTP é recusado pelo cliente produtivo.

`make mobile-check`: análise/testes. `make experiences-mobile-contract`: stack real, apenas banco `flow_experiences_test` e bucket `flow-experiences-test`; recria schemas/limpa objetos exclusivamente desses destinos. Fixture de sessão/revogação só existe no binário Go de integração. Respostas Go são validadas contra OpenAPI, incluindo capa binária; sem logs de credenciais. Smoke não comprova OAuth/SMS ou picker físico.

Marca, IDs, HTTPS, provedores Identity, URLs legais, geocoding/mapa e homologação de galeria/EXIF/rede em aparelhos permanecem externos. Sem assets aprovados, reutilizam-se apenas tokens/componentes existentes, sem inventar logo.
