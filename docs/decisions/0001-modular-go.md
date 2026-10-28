# ADR 0001 — Monólito modular e plataforma Go

Status: aceito para PR-00. Data: 27/10/2026.

Contexto: Flow reinicia com escopo amplo e infraestrutura operacional ainda pequena. Microserviços adicionariam contratos distribuídos, consistência eventual e deploys sem necessidade medida.

Decisão: Go suportado mais recente, net/http + chi, PostgreSQL/PostGIS, pgx/sqlc, goose, Redis e RabbitMQ. Uma API modular, composição explícita e schema técnico mínimo. Worker só surge com consumidor real; gateway pode separar processo após medições de conexões/signaling. Sem NestJS, Rust, blockchain ou framework adicional. Infra local via Compose; CI via GitHub Actions.

Consequências: deploy e transações simples, limites de módulo disciplinados por revisão. Não criar entidades antecipadas. Redis indisponível afeta readiness conforme configuração da fundação, a reavaliar com modo degradado real. Alternativa rejeitada: serviços por domínio sem necessidade operacional.
