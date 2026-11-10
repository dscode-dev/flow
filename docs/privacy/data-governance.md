# Governança de dados — fundação

Status: fundação PR-00 e inventário Identity PR-01.A implementado; validações automatizadas usam dados sintéticos. A exceção de acesso temporário local usa o telefone autorizado pelo proprietário, conforme inventário ao final. Segurança implementada não constitui declaração de conformidade LGPD. Produto, segurança e responsável de privacidade devem validar cada tratamento antes da ativação com pessoas reais.

## Tratamento mobile Experiences — PR-02.B

Formulário, agenda UTC/IANA, endereço/ponto confirmado e seleção de capa são fornecidos pela pessoa para gerir sua experiência. Sem posição do aparelho, histórico de localização/busca, rastreamento, câmera, vídeo ou analytics novos. PUBLIC e UNLISTED apresentam a consequência de divulgar o local antes de publicar; UNLISTED não significa convite privado. Base/avisos/menores e fornecedores ainda exigem validação dos responsáveis, sem nova declaração de conformidade.

| Tratamento / dono | Destinatários e retenção local | Controle |
| --- | --- | --- |
| Formulário/rascunho e tentativa idempotente / mobile Experiences | Em memória durante a edição; após API confirmar, persistência do backend segue inventário abaixo. Sem banco offline/backup local de drafts | Aviso ao descartar; saída/restrição/mudança de conta limpa memória e cancela requests. Encerramento do processo perde alterações não salvas; não afirmar recuperação offline |
| Galeria / OS, mobile, Media/S3 | Picker recebe escolha explícita; pode criar cópia temporária em cache do OS/plugin, sujeita à limpeza do sistema. App não cria cópia permanente própria. Bytes em memória durante upload/edição | Sem solicitação de metadados completos. Limites antes de decodificar; orientação aplicada e metadados removidos em isolate antes de transmitir. Servidor verifica/reencodifica novamente. Seleção Android recuperada exige confirmação, sem associação automática |
| Autorização S3 temporária / Media e mobile | Fields/URL somente em memória da intenção de upload, TTL5min; apenas destino autorizado recebe bytes | Nunca bearer/cookies Flow no storage, logs ou analytics de capacidade; sem assinatura em crash report/arquivo público |
| Capa lida / mobile Experiences | Bytes e pixels somente no widget autorizado; sem ImageProvider/cache global/disco. Descarte em saída, background, mudança de capa ou conta/restrição | GET bearer no-store; nova autorização ao retomar. 404/403 remove representação antiga; redaction não exibe detalhes, coordenadas, ticket ou capa |
| Ticket externo / mobile | Navegador/aplicativo externo só recebe URL após confirmação de saída. O fornecedor escolhido pode receber dados de navegação conforme sua política | HTTPS sem credenciais/fragmento/IP/porta não padrão; sem WebView privilegiada, fetch de preview, checkout ou promessa de verificação |

`LocationSearch` permanece desativado sem configuração aprovada; não há envio a Mapbox nem resultados artificiais. Ativação futura de geocoding/mapa precisa inventário de consultas, fornecedor/região/telemetria, avisos e retenção próprios. Diagnósticos atuais são categoria e request_id sanitizado, sem textos, posição, imagem, bearer ou autorização de upload. A homologação física da galeria, caches de OS, EXIF e rede ainda deve ser executada; testes sintéticos não substituem revisão/aceite com dados reais.

## Inventário Experiences / Media — PR-02.A

Finalidade: autoria/publicação/consulta de experiências físicas e capa verificada; sem registrar presença, compra, relacionamento ou rastreamento. Fonte: documento explicitamente fornecido pelo criador e arquivo escolhido; autor é referência opaca de Identity. Responsáveis provisórios: engenharia mantém controles; Produto/Privacidade definem audiência, base/avisos/menores, fornecedor/região e prazos antes de pessoas reais. Publicação PUBLIC e link UNLISTED divulgam local/descrição/capa a outras contas; UNLISTED não é um grupo de convidados. O PR-02.B deve mostrar essa consequência antes de publicar, especialmente para residência, menores ou contexto que revele informação íntima.

| Conjunto / dono | Conteúdo, uso e destinatários | Retenção/descarte e controles |
| --- | --- | --- |
| experiences.experiences / Experiences | UUID/autor, título/descrição/categoria, agenda UTC/IANA, visibilidade/estado/moderação, ponto físico, venue/endereço opcional, capacidade informativa, ticket externo/capa e versões | Histórico preservado sem delete automático até política/direitos próprios; cancelamento/arquivo não provam eliminação. PRIVATE só autor, UNLISTED direto autenticado, público só após publicar; histórico terceiros redigido e WITHHELD 404 |
| ponto/endereço / Experiences | Lugar explicitamente escolhido, geography 4326 arredondado6casas; localização precisa pode revelar terceiros/contexto | Sem posição do usuário/rota/histórico de busca. Mesma audiência do agregado; nunca em logs/eventos. Precisão disponível deve ser deliberada na UX; origem de filtro PostGIS transitória |
| categories / Experiences | Catálogo controlado e labels de apresentação, sem pessoa associada | Persistente; desabilitar conserva FK histórica; acesso autenticado ao catálogo habilitado |
| idempotência/quotas / Experiences | Conta opaca+key/hash/snapshot original (pode conter local e descrição do draft), contadores por dia UTC | Snapshot TTL24h, excluído pelo comando de manutenção; acesso interno apenas, não analytics. Quotas >2d removidas. Documento idempotente deve ser tratado como dado restrito, não log |
| restrictions / Experiences | Autor, blocked_until, razão categórica, updated_at | Até revisão/política operacional; sem motivo livre pessoal. Não expõe em resposta; gestão privilegiada futura |
| uploads / Media | Dono/UUID/key/hash, MIME/tamanho, chaves S3, expiração/estado, dimensão/hash verificado | Staging limpo após expiração+1h; arquivo sem binding removido após24h; tombstones DELETED apagados após30d. Lifecycle staging no fornecedor cobre uploads tardios; configurar/monitorar operação |
| arquivos/bindings / Media | Bytes fornecidos (incluem metadados temporariamente), variante reencodificada sem EXIF/trailer e vínculo à experiência | S3 privado; só variante verificada é exibida pela autorização da experiência; sem URL arbitrária/público irrestrito. Arquivo associado segue ciclo de origem/direitos; nenhuma cópia P2P/CDN atual |
| auditoria / Experiences e Media | Ator/recurso/ação/UTC/request_id; experiência inclui versão | Limpeza técnica após180d no comando, acesso restrito separado; sem texto/posição/imagem/prova externa. Política/integridade/retenção operacional precisam de validação |
| eventos / integração | experience_id/version/status/visibility em outbox, sem conteúdo/local/URL/PII | Retenção da plataforma/replay; pendente não é apagada por idade. Futuro relay/consumidores devem revalidar fonte e aplicar invalidação, sem reabrir audiência |
| capacidade POST / cliente e S3 | Autorização temporária com chave/assinatura/fields/tamanho/MIME; não é bearer Flow |5min, nunca logs/analytics/persistência pública. Cliente não envia Authorization Flow ao storage. Servidor lê e reencodifica antes de marcar READY |

`experiences-maintenance` implementa prazos técnicos acima em batches limitados, sem serviço de cron de produção provisionado. Ações de exportação/eliminação/restauração de backup devem coordenar agregado, snapshot idempotente, bindings, objetos/variantes, outbox, índices futuros e processadores, preservando somente histórico mínimo autorizado. Não existe endpoint de direitos nem aprovação automática de retenção indefinida neste PR.

S3 local real (SeaweedFS) usa dados sintéticos/volume privado; não comprova aprovação de fornecedor produtivo, região, transferências, criptografia em repouso ou backup. Antes de nuvem, provisionar bloqueio de acesso público/ACL, TLS, credencial mínima, lifecycle, custo/limites, observabilidade sanitizada e revisão contratual de operador. Reencodificação remove metadados mas não avalia conteúdo impróprio nem autoriza divulgação de pessoas fotografadas. URLs de ticket não são buscadas pelo backend, verificadas como pagamento nem compartilhadas em eventos.

Referências oficiais: [LGPD compilada](https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709compilado.htm) e [orientações de segurança da ANPD](https://www.gov.br/anpd/pt-br/centrais-de-conteudo/materiais-educativos-e-publicacoes/anonimizado___guia_orientat-_seg_da_inf_p_atpp.pdf), consultadas em 27/10/2026. Finalidade, necessidade, transparência e segurança orientam as decisões; revisão jurídica/privacidade específica permanece necessária. Prazos abaixo são propostas técnicas, não prazos legais inferidos.

## Classificação e minimização

| Classe | Exemplos futuros | Regras de tratamento |
| --- | --- | --- |
| Público aprovado | Descrição de experiência publicada, mídia com audiência pública explícita | Publicação exige decisão de audiência; público não significa retenção ilimitada ou ausência de direito de eliminação |
| Interno | Métricas agregadas de operação, configuração sem segredo | Acesso por função; avaliar possibilidade de reidentificação |
| Pessoal restrito | Perfil, identificador de conta, participação, interações, IP e audiência | Finalidade documentada, autorização por recurso, exposição mínima, exportação/eliminação rastreável |
| Alto risco operacional | Localização precisa, mensagens, telefone, dados de menores ou contexto que revele atributos íntimos | Necessidade e avaliação de impacto antes de coletar; evitar precisão/histórico desnecessários; acesso privilegiado justificado |
| Segredo | Senhas, chaves, tokens, concessões de peer, URLs assinadas | Nunca em logs, eventos ou contratos públicos; secret manager no servidor e Keychain/Keystore no mobile |

Esta classificação é de engenharia; localização e telefone não são automaticamente classificados aqui como categorias legais de dados sensíveis. Conteúdo social/contexto pode revelar informações sensíveis e exige avaliação antes de lançamento.

Localização só quando a ação exigir e com permissão contextual; priorizar área aproximada. Não iniciar rastreamento contínuo ou background. Não pedir contatos, câmera, microfone, biometria ou localização no bootstrap. Permissão de OS não substitui definição de finalidade/base legal. Não incluir telefone, coordenadas, token, URL assinada, header Authorization ou payload de mensagem em telemetria.

## Inventário obrigatório por feature

Registrar módulo dono, categorias, titular, fonte, finalidade, base legal validada, necessidade, destinatários, operadores/suboperadores, país/região, direitos, controles de acesso, retenção, descarte e responsável. Sem inventário aprovado, dados pessoais reais não entram na feature. Desenvolvimento usa somente dados sintéticos centralizados quando necessários, nunca dump de produção.

## Retenção e descarte

| Conjunto | Proposta inicial / gate antes do uso |
| --- | --- |
| Logs técnicos sanitizados | Proposta: 14 dias; traces 7 dias; confirmar necessidade, custo e política antes de produção |
| Auditoria privilegiada | Proposta: 180 dias com acesso separado e integridade; validar finalidade e eventual obrigação específica |
| Outbox publicada/inbox | Proposta: 7 dias outbox publicada, 30 dias inbox, subordinados à janela máxima de replay; não apagar deduplicação antes de encerrar replay/redelivery |
| Outbox pendente / DLQ futura | Nunca limpeza silenciosa por idade; alerta e resolução controlada, respeitando eliminação/minimização do payload |
| Sessões/credenciais | PR-01.A: access 10m padrão, sessão absoluta 30d padrão, refresh rotativo e segredos SHA-256; histórico até expiração absoluta +30d |
| Localização | Fundação não coleta localização do usuário; PR-02.A persiste apenas o ponto explicitamente escolhido para a experiência, sem histórico de buscas ou rastreamento |
| Perfil, participação, social e mensagens | Definir por finalidade no ciclo do módulo; sem prazo genérico indefinido |
| Mídia, variantes, CDN e caches de peers | Mesma política de audiência/remoção da origem, TTL de cache curto, revogação e inventário de cópias; P2P não permite garantir recuperação de cópia já recebida |
| Backups | Proposta: janela de 30 dias; acesso mínimo, criptografia, teste de restore e reaplicação de solicitações de exclusão antes de voltar ao serviço |

PR-00 não executa jobs automáticos de retenção: não há eventos/dados de domínio. Antes do primeiro evento, implementar limpeza segura com métricas e testes, garantindo relação entre replay, inbox e TTL. Na eliminação futura, propagar por módulo, índices, objetos/variantes, notificações e processadores; registrar resultado mínimo sem recriar o dado apagado. Exceções de retenção exigem justificativa, prazo e acesso restrito. Não prometer eliminação instantânea de backups ou aparelhos de terceiros.

## Terceiros e transferência

Antes de Mapbox, S3, CDN, push, SMS/e-mail, analytics, crash reporting, STUN/TURN ou observabilidade externa: revisar finalidade, dados transmitidos, SDK/permissões, telemetria padrão, retenção, região, subprocessadores, contrato de operador, controles de exclusão, incidentes, credenciais, custos e avaliação de transferência internacional quando aplicável. Nada disso está aprovado apenas por constar na arquitetura. Desabilitar coleta opcional por padrão até revisão.

## Gates de validação

- **PR-01:** responsável por privacidade, inventário de Identity, base legal revisada, avisos claros, política de sessão, rate limits antiabuso, direitos de titulares e política de menores definidos antes de onboarding real.
- **Radar:** justificar localização, precisão e TTL; testar recusa/revogação; validar inferência de participação e exposição de localização de terceiros.
- **Social/Media/P2P:** audiência, moderação, remoção, metadados EXIF, integridade, fornecedores e exposição de IP; avaliar relatório de impacto conforme risco.
- **Admin:** menor privilégio, MFA e trilha resistente a alteração antes de habilitar ações reais; separar suporte de leitura de segredos.
- **Pré-produção:** revisar documentação legal, contratos, política de retenção, exportação/eliminação, incident response e restauração, sem assumir que checks de código equivalem a conformidade.

Responsabilidade provisória: engenharia mantém inventário/controles; produto define finalidade/UX; responsável de privacidade e assessoria validam bases e obrigações. Nomes, canal de titulares, procedimentos e responsáveis formais devem ser definidos antes de usar dados reais. Incidentes precisam de triagem, contenção e avaliação de comunicação pelas pessoas responsáveis, com prazos regulatórios verificados no momento do procedimento; não há rotina operacional de incidente implementada nesta fase.

## Inventário Identity — PR-01.A

Finalidade técnica: provar controle de um dos três métodos, manter uma conta interna e suas sessões, impedir abuso e oferecer primeiro acesso. Base legal, avisos, política de menores, responsáveis e canal de titulares continuam dependendo de validação de produto/privacidade; nenhum login de pessoa real foi observado nesta execução.

| Conjunto / dono | Categorias, fonte e destinatários | Retenção técnica implementada / acesso |
| --- | --- | --- |
| identity.users / Identity | UUID interno, status e timestamps de criação/autenticação/onboarding; fonte: transação de conta | Enquanto conta existir; exclusão/anonimização definitiva exige fluxo de direitos futuro. active/suspended/disabled/deleted não equivalem a eliminação |
| identity.profiles / Identity | Nome exibido e handle fornecidos pela pessoa, avatar_ref nulo no ciclo; sem perfil social completo | Ciclo da conta e direitos; somente a própria conta via API atual. Sem nome/e-mail/foto copiados do OAuth |
| identity.auth_identities / Identity | Provedor e sub verificado, ou HMAC de telefone E.164; timestamps e revogação | Ownership é reservado após unlink. Retenção/eliminação de tombstone precisa ser validada antes de dados reais para equilibrar proteção contra transferência e direitos; não alegar prazo ilimitado legalmente permitido |
| identity.devices / Identity | UUID servidor, android/ios, versão e label opcional declarada; sem hardware ID/fingerprint | Remover quando sem sessão e sem uso por 30 dias; label não é prova de posse nem informação pública |
| identity.sessions / Identity | IDs de conta/dispositivo, provedor de autenticação, tempos e razão categórica de revogação | Até expiração absoluta +30 dias; próprio titular lista/revoga. Suspensão e revogação são verificadas no banco em cada request |
| access/refresh_credentials / Identity | SHA-256 de segredos aleatórios, seletor UUID e histórico de uso; nenhum bearer cru | Access após expirar +24h; refresh até expiração absoluta da sessão +30d, inclusive usado, para detecção de replay |
| identity.challenges / Identity | Referência HMAC de telefone/nonce, SID Verify, propósito, origem HMAC, expiração, tentativas e consumo | Expiração +24h; nenhum OTP, texto SMS, telefone ou token externo em claro no banco. Telefone passa em memória para envio Twilio |
| identity.rate_limits / Identity | Contadores por janela, número/origem pseudonimizados e teto global | Fim da janela +24h; somente operação privilegiada pode consultar agregados, sem expor HMAC a suporte geral |
| identity.audit_events / Identity | Ator/alvo IDs opacos, ação, resultado, motivo categórico, correlação e UTC | 180 dias técnicos propostos, sujeitos a validação; acesso de segurança segregado. Não inclui OTP/token/e-mail/telefone/payload OAuth |
| identity.provider_notifications / Identity | Digest SHA-256 de jti Apple e timestamp de recebimento | Oito dias, maior que janela aceita de sete; payload/relay e-mail não são persistidos |
| integration.outbox / Integração | Fatos implementados com user_id e envelope, sem segredo/subject/telefone | PR-00: pendentes não são apagados silenciosamente; relay e política de replay serão implementados com operação própria, sem prometer entrega RabbitMQ já ativa |

HMAC não torna telefone/origem anônimos: permanecem dados pseudonimizados e vinculáveis. Chave separada em secret manager, backup protegido e acesso restrito são necessários; trocá-la sem migração controlada quebra lookup PHONE. Não coletar IP cru em tabelas/auditoria Identity; origem IPv6 agrupada /64. Não solicitar localização ou contatos neste ciclo.

Tratamentos externos: Twilio recebe telefone E.164 e processa/verifica OTP; Google e Apple comprovam identidade por seus próprios fluxos. Flow valida tokens no servidor e não conserva e-mail, private relay, nome retornado uma vez ou authorization codes. Revisar contratos de operador/suboperador, regiões, transferência internacional, logs/retention do Verify, consentimento SMS, canal de exclusão e incidentes antes de habilitar credenciais reais. Não presumir que o TTL local apaga registros no fornecedor.

`identity-retention` aplica os prazos técnicos por transação; deverá ser agendado diariamente com papel de banco apropriado e monitoramento. Não remove contas, perfis, reservas de ownership, outbox pendente ou backups. Exclusão de conta, exportação e solicitações de titulares permanecem processo operacional a definir, sem endpoint público fictício. Antes de publicar, responsável de privacidade deve aprovar os prazos e o destino das reservas revogadas. Notificação account-deleted Apple revoga acesso; não comprova atendimento de um pedido de eliminação Flow.

Quotas e auditoria são controles de segurança, separados de analytics. SMS tem riscos residuais de SIM swap, número reciclado e interceptação; login SMS não concede autorização para ações financeiras/admin futuras. Perda do único método exige escalada conservadora documentada em `docs/features/identity.md`, sem reconhecimento por atributos de perfil.

## Fluxo mobile de identidade — PR-01.B

- **Entrada:** telefone/código e nome/handle em campos da UI; país inicial BR editável. Telefone e OTP ficam em memória durante a tentativa e são enviados apenas à API. Sem contatos/localização, fingerprint ou analytics. Não adicionar e-mail/telefone social ao perfil automaticamente.
- **Prova externa:** SDK Google/Apple comunica com seu provedor. ID token/nonce/state permanecem transitórios e vão somente ao endpoint de prova Flow; nome, e-mail, avatar e código de autorização não entram no payload Flow. O fornecedor pode tratar dados conforme contrato próprio; responsáveis devem validar destinatários/regiões e avisos antes do uso real.
- **Persistência local:** refresh, session_id, expiração e, em sessão Apple, identificador nativo usado exclusivamente em CredentialState. Uma chave versionada no Keychain/armazenamento criptografado Android; access e perfil somente em memória. Android backup desativado; Keychain this_device. Journal pendente remove segredo antigo antes de refresh. Saída/expiração/restrição limpa o registro; falha de limpeza bloqueia novo login. Retenção local limitada à sessão absoluta (padrão servidor 30d), com checagem no bootstrap; expiração não é job de eliminação enquanto app está fechado.
- **Suporte:** apenas mensagens categóricas e request_id sanitizado na tela; logs locais só classificação. Não copiar payload, JWT, OTP, telefone, e-mail ou segredo para tickets/screenshots. Logout offline não comprova revogação de servidor; revogação não equivale a eliminação de conta/dados.
- **Publicação:** logo/URLs de termos e privacidade, política de menores, base legal/finalidade, contratos de provedores, destinatários/regiões e processo de direitos continuam dependentes de validação dos responsáveis. URLs só ficam ativas por configuração explicitamente aprovada. Não há aceite fictício nem declaração automática de conformidade.


### Revisão de fechamento PR-01.C

A notificação nativa Apple em foreground transporta somente um sinal de mudança, sem subject, usuário, e-mail ou payload. CredentialState usa o metadado Apple já criptografado; não introduz nova coleta nem analytics. Sessão emitida mas não persistida tem revogação tentada por access; saída por access expirado só renova após remover o segredo antigo do disco e se não havia rotação em voo. Falha/rede/401 não autorizam afirmar revogação remota confirmada.

O auditor de configuração lê apenas os arquivos explicitamente selecionados/ambiente e publica categorias booleanas, sem valores. O template mobile aceita somente chaves públicas; segredos Twilio/HMAC/assinatura não são Dart defines. Fixtures do contrato ficam em test/banco isolado, nunca em configuração de produção. Evidências físicas/externas, base legal/finalidade, menores, destinatários/regiões, URLs publicadas, política de retenção e execução operacional ainda exigem aprovação/evidência dos responsáveis; o código não substitui esse aceite.

## Exceção explícita de teste: telefone temporário

O proprietário autorizou um número/código para acesso local ao app sem envio de SMS. Valores ficam somente no `.env` privado do backend; Flutter recebe apenas flag visual. Não há destinatário SMS externo para esse número nesse modo. Referência de entrega é opaca/HMAC, e identidade persistida segue minimização de Identity. Conta/sessões/experiências são reais no banco de desenvolvimento; desativar novas entradas não é eliminação ou revogação automática. Sem logs de credenciais, uso produtivo, vínculo de identidade ou reautenticação por esse provedor. [Uso e desativação](../features/development-phone-login.md).

## Complemento PR-03 — descoberta Home

Região/categoria escolhidas são critérios transitórios, não preferências persistidas ou histórico. Nome da região fica somente em memória; API recebe centro arredondado a duas casas decimais, raio e categoria opcionais, calcula distância via PostGIS e não grava parâmetros. Distância exibida é aproximada e relativa ao centro escolhido, não ao aparelho. Sem GPS, permissão de localização, background tracking, inferência por telefone/IP ou analytics novo. Continuar sem localidade usa agenda pública geral. Formulário explica finalidade e que não há geocoding por nome configurado.

Sessão/conta/restrição removem cards, critérios, timers, requisições e pixels locais; navegação/resume/tempo revalidam conteúdo no-store. Dados públicos de experiências seguem audiência PR-02; UNLISTED/PRIVATE nunca entram na composição, mesmo quando o solicitante é dono. Detalhe/capa mantêm autorização independente. Nenhuma imagem ou URL assinada permanente é persistida pelo módulo Home. Queries/bodies/URLs não entram nos logs existentes; diagnóstico por categoria/status/request_id. Geocoding/mapas, eventual GPS e novos sinais pessoais exigirão inventário/fornecedor/finalidade aprovados no ciclo próprio. Não há história de navegação ou posição para treinar recomendações.

## Complemento PR-04 — Radar/Mapbox

Radar adiciona consulta transitória de viewport/categoria/período/raio e renderização Mapbox. Visibilidade continua PUBLIC/PUBLISHED/VISIBLE/fim futuro; não há contagens ou pins de PRIVATE/UNLISTED. Câmera/filtros/seleção apenas em memória da conta, descartados ao sair/restringir/trocar; não há banco de histórico. Bounds representam a área exibida, não prova da posição física; logs omitem bounds/query/ponto/token/mensagem bruta de SDK. Métricas locais somente duração/contagem de itens públicos/categorias operacionais; sem novo envio a analytics.

Localização é opcional e depende de ação/explicação contextual, acesso durante o uso, baixa precisão e apenas primeiro fix, cancelável em12s/background/conta/dispose. Android só COARSE; sem FINE/background/foreground location service no merge; iOS apenas WhenInUse com bypass Always no build SPM. Dados não usados (altitude/velocidade/heading/precisão) não seguem à API; centro arredondado a2 casas antes de camera/raio. Mapbox location puck permanece desativado. Não há stream persistente, compartilhamento social ou trilha de deslocamento. Negação/revogação/serviço desativado preservam descoberta manual.

Novo fornecedor: Mapbox para mapas/estilos/tiles/fontes/SDK. Pode receber token público, IP/metadados técnicos, recursos da área escolhida e telemetria conforme configuração/termos; cache nativo pode persistir tiles/estilos geográficos. Attribution/wordmark e opt-out nativo ficam visíveis/clicáveis; informações também no app. Não afirmar que todo dado é anônimo ou que o fornecedor não trata localização. GeoJSON de experiências públicas é entregue localmente ao SDK; não foi configurado endpoint de ingestão de conteúdo/identidades no fornecedor. Geolocator é código de acesso ao OS, sem geocoding externo ou novo destinatário de rede configurado.

Token público somente em configuração local/de build, nunca segredo administrativo/download no mobile. Proprietário confirmou ausência de token; execução real de Mapbox, avaliação contratual/billing, finalidade/base/avisos de terceiros/menores/região/retenção/opt-out e homologação física continuam pendentes. Sem declaração automática de conformidade ou aceite simulado. [Configuração/fluxos e gate](../features/radar.md).

## Complemento PR-05 — Explorar e Flows

Busca textual e filtros são processados para a consulta atual, em memória da conta, sem histórico/analytics de buscas ou views. Região manual aproximada a2 casas; sem novo GPS/inferência de localização. Backend não registra texto, coordenadas, corpos, tickets/URLs ou erro bruto de ferramentas. PostgreSQL/S3 existentes persistem dados; FFmpeg/FFprobe executam localmente no worker Go. video_player oficial Flutter usa players nativos, sem instrumentação nova de reprodução pelo app.

| Dado / finalidade | Retenção e destinatário | Controle |
| --- | --- | --- |
| Apresentação e referências por Experience | PostgreSQL enquanto vinculadas; owner/leitores elegíveis | PRIVATE nunca; PUBLIC conforme agenda/publicação; UNLISTED somente com consentimento explícito auditado, sem backfill. Desativar revoga consentimento/capacidades e muda versão |
| Consentimento e alterações | UTC/ator/versão/snapshot de audiência/refs em flow_audit,180 dias; configuração mantém aceite atual até revogar | Aviso antes da ativação UNLISTED; não é consentimento genérico de marketing nem declaração de conformidade/base legal |
| Imagens/vídeos da galeria | Staging S3 privado, depois imagem sanitizada ou MP4/poster sem metadados originais | Sem câmera/microfone novos. Até15s/limites bytes/resolução verificados. Conteúdo pode incluir rostos/vozes/local; direitos/avisos exigem revisão própria do criador/produto |
| Órfãos/diagnóstico | Staging expiração+1h; finais sem associação24h; tombstones7 dias; PROCESSING protegido por lease | Limpeza em lotes com locks. Despublicar restringe leitura, não apaga automaticamente mídia associada. Pedidos de eliminação seguem política do agregado |
| Capacidade de leitura | API30s, vinculada a sessão/conta/recurso/versões; player/memória de widget | Cada GET/range revalida autorização. No-store, sem redirect S3/URL permanente. Bytes já entregues/resposta em andamento não podem ser recuperados |

Worker limitado em CPU/memória/pids/tmpfs/tempo, não root, protocolos locais e somente configurações DB/S3/mídia necessárias; sem segredos Identity/SMS. Inspeção técnica não equivale a moderação audiovisual. Sem P2P, share sem deep link aprovado, feed pessoal ou métricas sociais. Homologação física, produção HTTPS, custos, revisão jurídica/menores continuam tarefas explícitas do proprietário. Ver [ADR0010](../decisions/0010-explore-flows-exposure-media.md).

## Complemento PR-06 — participação, convites, agenda e check-in

Sem novo fornecedor ou permissão nativa. PostgreSQL e outbox existentes armazenam vínculos com a Experience; não há importação de contatos, telefone/provedor na lista de participantes, integração de calendário, GPS, reconhecimento facial, câmera/QR ou analytics de presença. Nome público/handle/ID interno são usados pelo organizador na conferência presencial; lista nominal é exclusiva do criador, não descoberta de quem compareceu.

| Dado / finalidade | Retenção e destinatário | Autorização e minimização |
| --- | --- | --- |
| Interesse/solicitação/confirmação/cancelamento/remoção/bloqueio contextual | Relação única PostgreSQL; titular e organizador nos escopos próprios | Interesse não reserva vaga; bloquear não é Social Graph global. Acesso privado exige convite válido/CONFIRMED e políticas atuais. Agenda de acesso perdido só mostra referência pessoal indisponível, sem título/local/horário privados |
| Convite individual | Um atual por Experience/destinatário; histórico mínimo em auditoria/outbox | UUID interno ou handle exato, sem pesquisa de contatos; erro uniforme para inelegíveis + quotas. Pendência expira em até168h/fim, default72h. Revogar/expirar retira acesso derivado, sem ampliar descoberta automática |
| Agenda pessoal | Consulta atual ao agregado e relações, sem cópia de horário/local ou calendário externo | Seções paginadas/autenticadas, fonte UTC/IANA; nenhuma lista privada de terceiros. Memória da tela apagada em background/conta/saída/expiração, detalhe privado de convidado revalidado em até60s |
| Código temporário de check-in | HMAC no banco, sessão emissora, TTL30..300s/default120s; expurgável após expiração+1 dia | Aleatório80bits, não reversível sem força bruta, uso único; bruto só em resposta/memória transitória. Organizador valida no local. Não salvar em dispositivo, log, evento, recibo, clipboard automático ou suporte. Remoção/cancelamento/rotação/revogação invalida |
| Registro de presença | Um por usuário/Experience, momento UTC/conferente/versão e eventual revogação | Independente de participação/pagamento; contestação e nova verificação preservam trilha. Código pode ser compartilhado: sem garantia automática de localização física/identidade civil. Não coletar trilha GPS para compensar essa limitação |
| Auditoria e fatos | Audit180 dias; outbox conforme governança compartilhada, sem apagar fatos pendentes | Ator/alvo/recurso/ação/UTC/versão/request_id e detalhes mínimos; eventos só IDs/estado/versão. Emissão do segredo é somente auditada, sem segredo/hash no evento. Leitura/exportação admin futura exige escopo/caso/audit próprios |
| Recibos e abuso | Idempotência24h; contadores por ator/minuto com expurgo após2 dias, lotes até500 | Hash de operação/corpo e resposta mínima, sem código bruto; tentativas recusadas também consomem quota. Logs omitem corpo/código/handle/tokens e identidade privada, sem métricas sociais inventadas |

Participações/convites/presenças persistem como histórico da relação enquanto os agregados/contas forem conservados; não foi implementado expurgo automático desses fatos nem calendário universal de retenção. Produção exige decisão aprovada de finalidade/base/retenção/eliminação/contestações e execução operacional de manutenção, incluindo implicações de experiências privadas e menores. Não declarar conformidade jurídica por implementação técnica. CONFIRMED é apenas um sinal para Event Space futuro, cuja autorização deverá ser reavaliada. [ADR0011](../decisions/0011-participation-capacity-checkin.md).

## Social — PR-07

Finalidade: compartilhar relatos e mídia, descobrir posts públicos, seguir pessoas e conter abuso. Reutiliza user_id/display_name/handle Identity e experiência existente; sem importar contatos/telefone/provedor/localização precisa. PUBLIC circula entre usuários autenticados elegíveis, FOLLOWERS exige relação atual. Nenhum consentimento UNLISTED de Flows habilita Social. Contagens refletem somente dados autorizados ao observador. Avatar/bio não são inventados quando falta distribuição/contrato.

| Dado | Política técnica efetiva | Necessidade/limite |
| --- | --- | --- |
| Post/comment/body/contexto/audiência | Ativo enquanto finalidade; exclusão apaga texto e revoga leituras/interações imediatamente; tombstone7dias e post só expurga após limpeza da mídia | Associação pública exige organizador/CONFIRMED e elegibilidade atual; cancelamento/restrição/audiência retira circulação; ausência de edição de audiência evita ampliação acidental |
| Like/follow/block | Relação única real; unfollow/unlike remove, block retira follows mútuos; referências de likes/comments de terceiros bloqueados são filtradas | Sem popularidade simulada/contatos/score. Desbloquear não refaz follows, interações históricas podem voltar a ser elegíveis. Exclusão de post expurga interações por FK |
| Mídia/variantes/hash | Mesmo S3 privado/worker do PR-05; staging5min+1h, órfão/post excluído removido após idade24h; tombstone7dias após limpeza/sem vínculo | Imagem sanitizada e vídeo real≤15s, sem metadados; capability30s revogável por cada GET/range. Nenhum cache público/persistente/P2P. Bytes já recebidos pelo observador não podem ser recolhidos remotamente |
| Report | Autor opaco, alvo, razão categórica, estado OPEN/RESOLVED,180dias desde criação | Triagem/contestação operacional, sem anexos/texto livre bruto ou contagem pública. Expurgo inclui pendências: operação precisa atuar antes do prazo e definir preservação legal aprovada antes de produção |
| Audit/outbox | Audit180dias, fatos duráveis com IDs mínimos/sem texto; consumidor revalida acesso antes de expor/notificar | Operador/caso também em inspeções CLI; credencial operacional separada. Outbox segue governança compartilhada, sem eliminar fatos pendentes no jobSocial |
| Receipt/quota/rascunho | Receipt24h só UUID/hash de comando; quota2dias; rascunho de tela sem disco, limpo em troca de conta/descarte/saída | Sem replay cego de mutações, preservar texto em falha de rede; conteúdo de feed/mídia em memória por até30s/lifecycle/saída |

Limpeza em lotes pelo worker existente a cada minuto, repetível após falha S3. Monitorar idade/atraso e comprovar exclusão antes de afirmar retenção cumprida. CLI de moderação/saídas UGC exigem escopo de caso, acesso mínimo e armazenamento operacional restrito; não colar em logs públicos. Processos de direitos/exportação/eliminação de contas/backups/retenção legal/menores e URLs legais seguem dependência externa dos ciclos anteriores. Implementação técnica não declara conformidade jurídica automática. [Políticas/operador](../features/social.md).

## Event Space — PR-08

Finalidade: compartilhar conteúdo no contexto de uma experiência com pessoas atualmente autorizadas. Reutiliza Identity, Participation e Social; sem novo fornecedor, permissão nativa, cópia de mídia, banco ou importação de contatos. [Matriz e operação](../features/event-space.md).

| Dados adicionais | Política e destinatários | Retenção/limites |
| --- | --- | --- |
| Contexto EVENT_SPACE/SPACE e vínculo ao UUID da Experience | Criador e CONFIRMED elegíveis; visitantes PUBLIC/UNLISTED só prévia, PRIVATE sem prévia nem por convite pendente. Nunca entra automaticamente no feed/perfil público | Mesma exclusão/limpeza Social. Histórico ENDED/CANCELLED/ARCHIVED permanece somente leitura autorizado, sem renovar audiência/finalidade por arquivamento |
| Settings, papéis e restrições locais | IDs/flags/version/UTC, sem outro cadastro de membros. Organizador nomeia, moderador sempre precisa manter elegibilidade. Restrição limita escrita e revoga papel | Relações persistentes da Experience, sem expurgo automático novo. Prazo de conteúdo ativo e eliminação dos agregados precisam governança antes de produção; não assumir retenção indefinida |
| Lista de participantes | user_id/display_name/handle/role somente para membros autorizados; filtros de conta/blocks, nunca telefone/provedor/check-in/presença | Memória de tela por janela absoluta30s/saída/background/sessão; sem persistência em disco ou exportação pública. Count confirmado exclui organizador |
| Ocultação local, reviews, audit e outbox | Motivos categóricos e IDs mínimos; moderador só metadados da denúncia, sem denunciante/body. Revisão local não resolve denúncia global. Leituras sensíveis auditadas | Review acompanha exclusão da denúncia180dias; audit180dias e outbox conforme política compartilhada. Não registrar texto/URL/capability/telefone nos logs |
| Galeria e capacidades | Referências aos mesmos objetos privados Social, autorização atual a cada GET/range; ocultação/removal/bloqueio retira novas leituras | Capability30s e cache de tela≤30s nominal. Bytes já baixados/copias externas não podem ser recuperados remotamente. Mesma limpeza S3/órfãos/tombstones do Social |

Removido continua podendo excluir seu post e seu próprio comentário conhecido conforme regras de sessão/contenção; não recupera acesso ao conteúdo de terceiros. Retorno elegível pode reexibir conteúdo histórico, sem restauração automática de papéis. Nenhum chat, presença contínua, push, DM, WebRTC ou P2P neste ciclo. Direitos, exportação/eliminação de conta, backup, preservação legal e política de menores continuam dependências de governança, sem declarar conformidade automática.
