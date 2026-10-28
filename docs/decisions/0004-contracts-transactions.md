# ADR 0004 — Contratos e transações antes das features

Status: aceito. Data: 27/10/2026.

OpenAPI documenta apenas probes reais, com validação estática e de respostas nos testes. Contratos de negócio surgem por ciclo. Envelopes de eventos/WebSocket são convenções sem canais ativos. API e app precisam tolerar evolução aditiva e tratar erro desconhecido com fallback seguro.

Eventos de integração serão gravados na outbox junto da alteração de domínio na mesma transação pgx. Inbox e efeito também são atômicos. Entrega ao menos uma vez e deduplicação por consumidor/event_id; não prometer exactly-once. Tabelas e consultas sqlc são a implementação mínima no PR-00; não há relay funcional sem produtor. Recursos técnicos não justificam tabelas especulativas de negócio.

Consequências: pequenas tabelas técnicas exigem manutenção futura (retenção, índice de fila, retries, lease e DLQ) no ciclo do primeiro evento. Testar rollback sem remover PostGIS compartilhado. Rejeitada publicação direta antes do commit, que pode causar perda ou evento sem estado confirmado.
