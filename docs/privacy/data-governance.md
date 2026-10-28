# Governança de dados — fundação

Status: arquitetura inicial, sem tratamento de dados de usuários no PR-00. Segurança implementada não constitui declaração de conformidade LGPD. Produto, segurança e responsável de privacidade devem validar cada tratamento antes da ativação.

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
| Sessões/credenciais | Expiração, rotação, revogação e eliminação serão definidas no PR-01; não reter tokens de acesso crus no banco por conveniência |
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
