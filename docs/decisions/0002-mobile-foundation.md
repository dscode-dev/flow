# ADR 0002 — Flutter incremental e identidade visual

Status: aceito, condicionado ao legado ausente. Data: 27/10/2026.

Decisão: Flutter estável 3.47.8 com Dart 3.13.7, Material 3, Riverpod sem geração obrigatória, go_router, Dio e abstração de secure storage. Tokens reutilizáveis e temas sem redesenho de produto. Login pertence ao PR-01. URLs por ambiente sem host padrão; falhas são sanitizadas.

Auditoria confirmou workspace e remoto vazios. Base em `apps/mobile` não equivale à modernização de Rolezin. Ao receber código, preservar fluxos, IDs, permissões, dados locais, ativos e Mapbox. Migrar por camadas, mantendo regressão verificável. Não inventar logo; scaffolds nativos e seus ícones padrão não são ativos aprovados para distribuição.

Alternativas rejeitadas: reescrever telas ainda não auditadas, migrar tudo de uma vez, mocks embutidos na UI ou autenticação permissiva. Consequência: associação de links e signing de produção dependem de domínio/IDs/ativos reais; readiness funcional do legado permanece pendente.
