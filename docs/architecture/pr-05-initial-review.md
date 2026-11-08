# PR-05 — inspeção inicial

08/11/2026, America/Recife. Branch main, HEAD 1b7c5f7 (commit preexistente, título “implementa PR-03”), árvore/índice limpos. Sem autorização de commit/push/merge/deploy. Preservar SDK fixado, Identity, configuração LAN, assinatura pessoal, Mapbox e volumes.

Lidos relatório PR-04, OpenAPI, Experiences (serviço/lifecycle/autorização/listagem), Home/Radar/queries/índices, mídia de capa/S3 e manutenção, Identity, componentes/tokens Flutter, repository/Dio/router/detalhes, inventário de privacidade e registro administrativo. PR-04 segue sem evidência de runtime Mapbox/homologação física; token informado como gerado não é evidência de execução do SDK.

Menor extensão: Explorar no módulo Experiences com busca PostgreSQL normalizada/indexada, filtros e cursor assinado. Apresentação Flow 1:1 subordinada a Experience, imagem própria/vídeo opcional ou capa autorizada. PUBLIC elegível conforme agenda/mídia; UNLISTED exige opt-in explícito auditado, nunca migração de exposição; PRIVATE excluída. Sem inferência de preço por ingresso externo porque não há preço no modelo.

Mídia reutiliza Storage S3 e autorização de upload existentes. Vídeo é processado por worker Go do mesmo backend/imagem, FFmpeg/FFprobe locais com limites e estados persistidos; sem subprocesso pesado no handler, serviço social/P2P ou dados fictícios no app. Distribuição progressiva por capacidade temporária verificada na API em cada requisição/range, permitindo revogar sessão/exposição; sem URL S3 permanente. Testes somente no banco/bucket isolados existentes.

Flutter reutiliza Identity/Dio/Riverpod, catálogo, detalhes/capas, picker e tokens Flow. Explorar com carrossel logo abaixo do header, busca cancelável e viewer vertical paginado, um player ativo e silencioso, pausa/descarte por rota/background/conta. Gestão contextual da apresentação sem reescrever formulário Experience. Compartilhamento externo só quando existir deep link aprovado; atualmente não existe.
