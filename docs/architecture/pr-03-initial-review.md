# PR-03 — inspeção inicial

07/11/2026. `main`, HEAD `b0fa1cde6fbc5e3b83a534da054ff90e8d5f5a0d`; árvore e índice limpos. Sem commit/push/deploy nesta execução.

Lidos relatório PR-02.B, especificação Experiences, integração mobile, OpenAPI, registro administrativo, listas/serviço/visões SQL, configuração e arquitetura Flutter (router, Identity, Dio, coordenadores, design system, detalhe/capa). A descoberta existente filtra PUBLIC/PUBLISHED/VISIBLE na visão `experiences.discovery`; tempo e PostGIS são aplicados pela query. Categorias são dados persistidos. Não existem editorial, preferências pessoais, notificações ou geocoding configurados.

Alteração mínima: GET autenticado `/v1/home`, no módulo Experiences, com seis consultas limitadas em um único statement e catálogo em consulta constante; nenhuma consulta por card. Usar visões e autorização de mídia existentes. Um índice parcial de recência complementa os índices de agenda/categoria/GiST. Home Flutter em `/app`, mantendo gestão e detalhes atuais. Região aproximada manual em memória e categoria contextual explícita, sem GPS/provedor inventado. Reutilizar Experience, ExperienceCover, badges, horários IANA, erros, Identity/Dio e tokens Flow. Contrato, testes PostGIS/Flutter e documentação acompanham a mudança. Não antecipar Radar/Explore/Social/Participation.
