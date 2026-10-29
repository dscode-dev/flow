# Governança de dados — fundação

Status: fundação PR-00 e inventário Identity PR-01.A implementado; validações desta execução usam somente dados sintéticos. Segurança implementada não constitui declaração de conformidade LGPD. Produto, segurança e responsável de privacidade devem validar cada tratamento antes da ativação com pessoas reais.

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
| Localização | Não persistir na fundação; qualquer precisão e TTL precisam de justificativa e gate do Radar |
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
