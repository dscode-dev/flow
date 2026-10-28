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

## ADM-002 — Identidade e privacidade (gate de PR-01)

- **Feature/módulo:** Identity/Privacy, planejamento sem feature implementada.
- **Recurso:** futuras contas, sessões, solicitações de titulares e medidas antiabuso.
- **Operações:** definir suspensão/restauração, revogação, suporte e pedidos de acesso/eliminação no PR-01; nunca consultar senha/token.
- **Permissões:** propostas `identity.accounts.read_limited`, `identity.sessions.revoke`, `privacy.requests.manage`; ação destrutiva e exportação com escopo e aprovação apropriados.
- **Auditoria:** ator/ação/alvo/motivo/resultado/UTC/correlação, dados mínimos e retenção validada.
- **Dependências:** contratos Identity e fluxo autenticado ainda serão definidos.
- **UI:** telas futuras com dados mascarados, justificativa e acompanhamento; sem impersonation implícita.
- **Ações operacionais:** recuperação de conta e incidentes com verificação de identidade definida por produto/segurança.
- **Privacidade/segurança:** acesso mínimo, MFA admin, segregação e revisão de base legal/direitos antes do uso real.
- **Status:** apenas gate/documentação; não há conta, login ou admin funcional.

Os módulos futuros (incluindo experiências, moderação, mídia/P2P, notificações e patrocínio) devem criar entradas próprias no ciclo que definir suas capacidades; não há operações especulativas implementadas no PR-00.
