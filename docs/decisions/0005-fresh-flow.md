# ADR 0005 — Flow como implementação nova

Status: aceito por decisão explícita de produto no PR-01.A. Data: 28/10/2026.

Flow substitui permanentemente Rolezin. Não haverá busca, migração, reconstrução ou dependência do legado. `apps/mobile` é a base oficial nova, criada no PR-00. O gate histórico de preservação do legado está encerrado por esta decisão, sem reinterpretar a auditoria ou afirmar uma migração inexistente.

PR-01.A entrega somente backend Identity. Telas e integração Flutter pertencem ao PR-01.B. Identificadores de aplicativos, marca, configuração dos provedores e testes de release continuam exigindo valores reais; não são bloqueios para implementar e validar localmente o backend. Nenhum teste físico faz parte deste ciclo.
