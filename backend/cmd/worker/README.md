# Worker futuro

Nenhum consumidor executável no PR-00. O relay de outbox será implementado junto do primeiro evento real, com confirmação do broker, retries limitados, DLQ e métricas. Mesmo módulo Go e imagem; processo separado somente quando houver tarefas assíncronas reais. Nenhum contêiner ocioso no Compose.
