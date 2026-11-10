# PR-08 — revisão inicial

Revisão realizada antes das alterações: branch `main`, HEAD `da69b92ae8858c7ec5f3242dbff1959aaddde8c3`, index e árvore limpos. Não houve reset, descarte, commit, push, merge ou deploy.

Foram lidos o relatório PR-07, migrações 00001–00009, OpenAPI 1.6.0 (92 operações), regras de Experiences/Participation e consultas, serviços, moderação, mídia e Flutter Social. Também foram revisados o inventário de privacidade e admin-capabilities. Configurações locais privadas foram preservadas.

Pontos de extensão: `social.posts.context`, `social.can_read`, documentos SQL, serviço Social e suas transações/recibos, mídia SOCIAL e worker Go já existentes. Participation continua autoridade sobre CONFIRMED, convites e bloqueios. O lock da Experience permite serializar revogação e mutações contextuais. A navegação e os stores existentes já oferecem cancelamento, segregação de conta e TTL.

Decisão: contexto explícito EVENT_SPACE/SPACE, identidade igual ao UUID da Experience, sem backfill de posts e sem novo serviço, banco, pipeline ou sistema de participação. Novas tabelas guardam somente configurações, papéis, restrições locais e revisão contextual de denúncias. Estados temporais são derivados da agenda. A implementação e os limites finais estão no relatório de conclusão e na ADR0013.
