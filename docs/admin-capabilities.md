# Registro de capacidades administrativas

Documento cumulativo obrigatório. Cada PR com impacto administrativo deve adicionar/atualizar entrada e status, inclusive se a UI admin for futura. Plataforma administrativa não implementada no PR-00. Não interpretar permissões propostas como roles já existentes ou bypass de autorização.

## Modelo padronizado

```text
ID / feature ou módulo:
Recurso gerenciado:
Operações administrativas:
Permissões necessárias (ação/recurso/escopo):
Auditoria (ator, alvo opaco, ação, motivo, instante UTC, resultado, correlação):
Dependências de API/contrato:
Requisitos de UI de gestão:
Ações operacionais (aprovação, recuperação, rollback, limites):
Privacidade e segurança (minimização, segregação, retenção):
Status da implementação / PR / pendências:
```

## ADM-000 — Plataforma e saúde

- **Feature/módulo:** plataforma operacional PR-00.
- **Recurso:** disponibilidade da API, PostgreSQL, Redis, RabbitMQ, migrações e exportação de traces.
- **Operações:** consultar saúde, observar erros/correlação, aplicar migrações em ambiente autorizado; reiniciar processos via infraestrutura. Nenhum endpoint de reinício/migração exposto pela API.
- **Permissões:** propostas `operations.health.read`, `operations.telemetry.read`, `operations.migrations.execute`, `operations.services.restart`, com ambiente e segregação entre leitura e mudança; não implementadas em UI/API admin.
- **Auditoria:** execução de migração/restart por automação autenticada deve registrar operador, ambiente, versão, justificativa e resultado. Logs de acesso atuais não são trilha administrativa persistida. Goose registra versão no banco, sem substituir identidade do operador.
- **Dependências:** GET `/healthz`, `/readyz`, OpenAPI e comandos Compose/migrate; sem contrato admin de mutação.
- **UI:** futura visão de saúde por ambiente, versões e links de correlação sanitizados; não exibir DSNs, segredos ou dumps.
- **Ações operacionais:** restaurar dependências, retestar readiness, revisar falha de migration, aplicar down apenas com aprovação operacional e backup quando houver dados. Não expor comandos arbitrários na UI.
- **Privacidade/segurança:** sondas públicas não mostram detalhes de infraestrutura; telemetria restrita e retenção aprovada. Nunca exportar corpo/header/token por suporte.
- **Status:** probes, migrações e logs implementados; gestão privilegiada, permissões admin e trilha persistente futuras.

## ADM-001 — Integração outbox/inbox

- **Feature/módulo:** integração técnica.
- **Recurso:** registros técnicos, falhas de entrega e deduplicação por consumidor.
- **Operações:** futuramente observar backlog, diagnosticar consumidor e reprocessar evento elegível com motivo; sem editar payload ou apagar inbox para forçar efeito.
- **Permissões:** propostas `integration.backlog.read`, `integration.replay.execute` por tipo/ambiente; replay privilegiado separado da leitura.
- **Auditoria:** ator, event_id, consumidor, motivo, tentativa e resultado sem payload pessoal; proteger contra alteração.
- **Dependências:** schema integration, envelope versionado e consultas sqlc; relay, DLQ e API de operação ainda ausentes.
- **UI:** futuro painel de contagens/idade e status, payload oculto por padrão, confirmação contextual para replay.
- **Ações operacionais:** limites de replay, pausa/retomada e recuperação documentados junto do primeiro produtor; impedir duplicação de efeitos.
- **Privacidade/segurança:** sincronizar retenção com janela de replay e solicitações de eliminação; acesso ao payload não é consequência da permissão de suporte.
- **Status:** tabelas e contratos implementados; nenhum evento publicado, relay, ferramenta de replay ou UI.

## ADM-002 — Identidade e privacidade (base PR-01.A)

- **Feature/módulo:** Identity/Privacy, planejamento sem feature implementada.
- **Recurso:** futuras contas, sessões, solicitações de titulares e medidas antiabuso.
- **Operações:** definir suspensão/restauração, revogação, suporte e pedidos de acesso/eliminação no PR-01; nunca consultar senha/token.
- **Permissões:** propostas `identity.accounts.read_limited`, `identity.sessions.revoke`, `privacy.requests.manage`; ação destrutiva e exportação com escopo e aprovação apropriados.
- **Auditoria:** ator/ação/alvo/motivo/resultado/UTC/correlação, dados mínimos e retenção validada.
- **Dependências:** contratos Identity e fluxo autenticado ainda serão definidos.
- **UI:** telas futuras com dados mascarados, justificativa e acompanhamento; sem impersonation implícita.
- **Ações operacionais:** recuperação de conta e incidentes com verificação de identidade definida por produto/segurança.
- **Privacidade/segurança:** acesso mínimo, MFA admin, segregação e revisão de base legal/direitos antes do uso real.
- **Status:** contas, três métodos, sessões, onboarding e operações do próprio usuário implementados em PR-01.A; gestão administrativa, permissões de operador e UI admin continuam futuras. Entradas ADM-003–012 detalham necessidades atuais.

Os módulos futuros (incluindo experiências, moderação, mídia/P2P, notificações e patrocínio) devem criar entradas próprias no ciclo que definir suas capacidades; não há operações especulativas implementadas no PR-00.

## Padrão comum das entradas Identity

Módulo: Identity/Privacy. **Todas as capacidades abaixo exigem** ambiente/escopo explícitos, menor privilégio, MFA de operador antes da ativação, auditoria de ator/alvo opaco/ação/motivo/UTC/resultado/correlação, acesso separado de analytics e dados mascarados na UI. Não mostrar OTP, ID token, refresh/access token, authorization code, chave HMAC ou payload bruto de provedor. Nenhum endpoint administrativo ou plataforma admin é entregue no PR-01.A. Dependências citadas são operações de domínio existentes ou contratos futuros a revisar; APIs `/v1/me` autorizam somente o próprio titular.

## ADM-003 — Consulta restrita de conta

- **Feature/recurso:** Identity / conta e perfil mínimo.
- **Operações/permissões:** procurar por UUID/caso autorizado e consultar status/perfil limitado; futura `identity.accounts.read_limited` com escopo de suporte.
- **Auditoria:** registrar também leitura e motivo do caso; não registrar texto de busca pessoal.
- **API/contrato/UI:** `identity.users/profiles` e modelo Me como base; contrato administrativo próprio futuro. UI mascarada, busca limitada, sem diretório/exportação irrestrita ou lookup público por telefone.
- **Ações operacionais:** identificar conta sem revelar vínculos de terceiros; escalar ambiguidade.
- **Privacidade/segurança:** referências PHONE são HMAC, não campo para operador copiar; nenhum segredo/telefone na resposta atual.
- **Status:** persistência/perfil próprio existentes; busca administrativa não implementada.

## ADM-004 — Status, suspensão e restauração

- **Feature/recurso:** Identity / estado active, suspended, disabled, deleted.
- **Operações/permissões:** suspensão/restauração/desabilitação futuras com `identity.accounts.status.manage`; reabertura de deleted exige processo específico, sem toggle genérico.
- **Auditoria:** motivo e decisão de autorização, antes/depois categóricos e revisão apropriada; auditoria resistente à alteração antes de habilitar.
- **API/contrato/UI:** enforcement de status já implementado no domínio; comando/API de alteração futura. UI apresenta impacto em acesso/sessões e exige justificativa.
- **Ações operacionais:** revogar sessões ao impor restrição e definir política de restauração; não publicar identity.account.suspended sem operação real.
- **Privacidade/segurança:** status deleted não afirma apagamento; nenhuma restauração por semelhança de perfil.
- **Status:** negação server-side testada; operações administrativas não implementadas.

## ADM-005 — Revogação de sessões

- **Feature/recurso:** Identity / sessão, device e família refresh.
- **Operações/permissões:** futuro revogar uma/todas em resposta a incidente, `identity.sessions.revoke`, distinto de leitura.
- **Auditoria:** ator, alvo, família/sessão, motivo/resultado; nunca segredo ou hash de credencial em tela.
- **API/contrato/UI:** domínio de revogação real; `/v1/me/sessions` é apenas self-service. UI futura mostra label/versão/tempos com escopo, sem impersonation.
- **Ações operacionais:** confirmar bloqueio de access/refresh após commit e distinguir evento de replay de simples expiração.
- **Privacidade/segurança:** device ID do cliente não prova posse; suporte não pode emitir nova sessão em nome da pessoa.
- **Status:** self-service, replay e revogação Apple implementados; interface administrativa futura.

## ADM-006 — Diagnóstico de identidades de provedor

- **Feature/recurso:** Identity / vínculo PHONE/GOOGLE/APPLE.
- **Operações/permissões:** diagnosticar estado/cronologia e conflito por referência opaca, `identity.providers.diagnostics.read`; reassociação de dono é operação separada e não autorizada por esta permissão.
- **Auditoria:** caso, ator, identidade opaca, resultado e acesso; sem subjects/e-mails/telefones brutos no registro.
- **API/contrato/UI:** unique provider/subject, link/reauth/unlink reais, webhook Apple verificado. UI futura indica ativo/revogado e configuração do provedor, sem payload/JWT.
- **Ações operacionais:** conferir client IDs/azp, configuração de nonce e credenciais no secret manager pelo papel técnico adequado; nunca transferir conflito silenciosamente.
- **Privacidade/segurança:** ownership revogado é reserva restrita, não lista de pessoas pesquisável; e-mail relay não é identidade.
- **Status:** domínio e provas implementados; diagnóstico administrativo futuro.

## ADM-007 — Abuso OTP e indicadores de entrega

- **Feature/recurso:** Identity / challenges, quotas e operação Verify.
- **Operações/permissões:** consultar agregados de tentativas/falhas/exaustão e orçamento, `identity.otp.abuse.read`; ajuste de orçamento requer `identity.otp.policy.manage` operacional separado.
- **Auditoria:** alterações de política/Geo Permissions, justificativa e responsável; não guardar OTP, número ou token como detalhe de incidente.
- **API/contrato/UI:** estado local sending/pending/failed/consumed/exhausted/superseded e expiração, contadores PG e console do fornecedor. UI deve distinguir pedido aceito de entrega observada, sem botão de bypass/envio irrestrito.
- **Ações operacionais:** conter pumping, desabilitar credencial/serviço por operação autorizada, revisar alertas externos/custos/rotas; não aumentar quotas automaticamente durante ataque.
- **Privacidade/segurança:** HMAC é pseudônimo restrito, budgets são reservas, sem armazenamento de telefone cru local.
- **Status:** quotas/adapter/auditoria de falha existentes; métricas de delivery real e UI dependem de credenciais/homologação.

## ADM-008 — Busca de auditoria de segurança

- **Feature/recurso:** Identity / audit_events.
- **Operações/permissões:** pesquisar ações por conta/caso/intervalo, `security.audit.read`; exportação requer `security.audit.export` específica e revisão.
- **Auditoria:** registrar leitura/exportação e motivo em trilha administrativa própria antes de liberar a feature.
- **API/contrato/UI:** eventos categóricos de segurança persistidos; API admin futura com filtros/limites. UI separada de analytics e payload oculto.
- **Ações operacionais:** correlacionar incidentes por request_id, confirmar replay/revogação sem consultar segredo; proteger cadeia de custódia.
- **Privacidade/segurança:** retenção técnica 180d sujeita a validação; WORM/exportação protegida ainda não homologados.
- **Status:** registros existentes e sanitização testada; busca/exportação administrativa futuras.

## ADM-009 — Escalada de suporte e recuperação

- **Feature/recurso:** Identity / caso de perda de acesso e reserva de ownership.
- **Operações/permissões:** registrar/escalar caso com `support.identity.case.manage`; recuperação efetiva exigirá permissão e política futuras, não inferidas do acesso de suporte.
- **Auditoria:** caso, decisões, prova aprovada categórica e revisores, sem anexos sensíveis indiscriminados.
- **API/contrato/UI:** não há endpoint de recovery/impersonation. UI futura mostra instrução para usar método ainda disponível e limita ações quando não há prova forte.
- **Ações operacionais:** escalar a segurança/privacidade; sem método restante e sem procedimento forte aprovado, não conceder acesso. Não restaurar por nome/e-mail/telefone alegado ou metadados.
- **Privacidade/segurança:** minimizar coleta de documentos e não transformar suporte em bypass de SMS/OAuth; respeitar risco de reciclagem de número.
- **Status:** procedimento conservador documentado; recuperação automática não implementada por decisão de segurança.

## ADM-010 — Solicitações de privacidade

- **Feature/recurso:** Privacy/Identity / inventário, retenção e pedidos de titulares.
- **Operações/permissões:** gerir casos com `privacy.requests.manage`; futura execução de exportação/eliminação possui aprovação/escopo próprios.
- **Auditoria:** prova de titularidade aprovada, escopo/destinatários, ações e resultado mínimo, sem recriar dados eliminados.
- **API/contrato/UI:** inventário/governança e CLI retention existentes; fluxo de direitos e UI administrativa futuros. Separar revogação de sessão, status deleted e eliminação comprovada.
- **Ações operacionais:** coordenar fornecedores, cópias, outbox e backups; registrar exceções justificadas e prazo de conclusão validado.
- **Privacidade/segurança:** validar base legal, prazos e destino dos tombstones antes de dados reais. Notificação Apple não encerra automaticamente um caso LGPD Flow.
- **Status:** inventário/política/comando técnico implementados; atendimento de direitos depende de processo aprovado.

## ADM-011 — Operação, métricas e retenção Identity

- **Feature/recurso:** Identity / disponibilidade, quotas, expiração e jobs de manutenção.
- **Operações/permissões:** ler indicadores agregados `identity.operations.read`; executar retenção `identity.retention.execute` com papel de banco próprio.
- **Auditoria:** operador/job/ambiente/política/resultado; logs de conclusão sanitizados, sem DSN.
- **API/contrato/UI:** CLI `/app/identity-retention`, probes PR-00 e contadores/challenges PG. UI futura mostra timestamps e sucesso/falha de execução; sem SQL arbitrário ou botão de apagar histórico de refresh ativo.
- **Ações operacionais:** agendar diariamente, alertar falha/atraso, testar restore e manter janela de replay; validar custos/latência de provedores em homologação real.
- **Privacidade/segurança:** retenção não remove usuários, identidades ou outbox; não alterar chave HMAC arbitrariamente. Métricas por pessoa/origem não são analytics públicos.
- **Status:** comando técnico e testes de janela implementados; agendamento de produção, painéis e alertas externos ainda não provisionados.

## ADM-012 — Configuração de confiança OAuth/Apple

- **Feature/recurso:** Identity / audiences/client IDs e notificações Apple.
- **Operações/permissões:** revisar allowlist e saúde operacional com `identity.providers.config.read`; mudança exige `identity.providers.config.manage` no processo de deploy/secret injection, sem endpoint público.
- **Auditoria:** IDs aprovados/ambiente, revisão, versão/configuração e resultado da homologação, sem secrets.
- **API/contrato/UI:** GOOGLE_CLIENT_IDS/APPLE_CLIENT_IDS, JWT/JWKS e webhook assinados; UI futura informa configurado, indisponível e homologado como estados distintos.
- **Ações operacionais:** rotação de chaves do fornecedor é suportada pela biblioteca JWKS; migração de App ID/equipe Apple ou fluxo OAuth exige revisão própria.
- **Privacidade/segurança:** não confiar em e-mail, nonce externo arbitrário ou token de outro app. Nenhum certificado/chave privada é exibido por suporte.
- **Status:** enforcement/adapters implementados; configuração e validação externas pendentes do proprietário.

## ADM-013 — Suporte à autenticação mobile

- **Feature/recurso:** PR-01.B / inicialização, providers, rotação, onboarding e saída.
- **Operações/permissões:** futura leitura de diagnóstico categórico com `identity.mobile.diagnostics.read`, separada de revogação e de mudança de configuração. Nenhuma API/tela admin criada neste PR.
- **Auditoria:** ator/caso/request_id/ambiente/versão/resultado mínimo; leitura futura deve ser auditada. Nunca solicitar OTP, refresh, ID token, nome/e-mail social ou dump do Keychain.
- **Fluxo de suporte:** distinguir configuração incompleta, cancelamento, quota, falha de entrega observada, refresh ambíguo, armazenamento seguro indisponível, revogação e restrição de conta. Orientar reautenticação após refresh ambíguo, sem tentar recuperar/reusar segredo antigo. Falha no armazenamento requer limpeza local explícita; logout offline não garante revogação remota.
- **Onboarding:** handle_unavailable não autoriza reserva/transferência por suporte; onboarding_required é decidido pelo backend. Cadastro/login uniforme não expõe existência de conta. Não unir contas por e-mail, telefone alegado ou nome.
- **Operação:** verificar bundle/package, audiences/azp, SHA-1, callback iOS, capability/provisioning Apple e origem API no ambiente certo. Credenciais/alterações continuam sob processo operacional, nunca botão de bypass. Apple Android está fora do fluxo web neste ciclo.
- **Status:** diagnósticos seguros no cliente e roteiro físico documentados; painéis, permissões e UI administrativas são futuros. Homologação externa de SMS/Google/Apple e aprovações de marca/privacidade pendentes.
