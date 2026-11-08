# Explorar — PR-05

`/explore`, protegido pela mesma sessão, acessível no Início. Ordem de produto: header Explorar, carrossel Flows com “Ver todos”, busca, categorias reais, filtros, resultados. Não modifica o layout do Radar nem implementa Social/Participação/Chat. Apresentações são cards proporcionais, não círculos de stories com estado “visualizado” inventado.

## Contrato

`GET /v1/explore/experiences`: q opcional até120 caracteres; category_id, phase LIVE/UPCOMING, from/until UTC juntos (sobreposição até31 dias), latitude/longitude/radius_m juntos (1–100km), limit1..50 (default20), cursor. Query estrita até4096 bytes, sem parâmetros desconhecidos/duplicados/vazios. Centro aproximado arredondado a2 casas; nome da região não sai do aparelho. Sem GPS obrigatório/mapa. Não há filtro gratuito/pago porque Experience não registra preço; URL externa não significa cobrança.

Somente PUBLIC/PUBLISHED/VISIBLE e ends_at>as_of pela visão descoberta existente, inclusive quando a experiência possui Flow. UNLISTED opt-in permanece exclusivo do carrossel/viewer Flows. Busca por título/descrição com tsvector português e unaccent gerado, índice GIN parcial, websearch_to_tsquery parametrizada; termos sem conteúdo léxico podem produzir vazio. Ordem starts_at/id ASC, sem rank de popularidade. Cursor HMAC15min por conta/filtros/tipo de consulta; não é intercambiável com Flows ou outras buscas. Limite+1 determina continuação. Timeout2s, resultados limitados, relógio/frescor do servidor.

## Mobile

Debounce350ms, cancelamento e geração descartam resposta obsoleta; mesma chamada em andamento é deduplicada. Paginação real e dedup por ID. Filtros de categoria/região também afetam o carrossel; texto/período/LIVE refinam a lista de busca. Região manual reutiliza RegionForm; raio é explícito e não depende de GPS. Busca/região ficam em memória da conta, sem histórico. Sessão limpa texto, filtros, requests e modais abertos. Retorno do detalhe revalida; rolagem da página é mantida pelo controller.

Um timer de até60s, reduzido por fronteiras temporais e páginas seguintes, retira resultados vencidos e oferece atualização. Sem polling de descoberta. Background cancela/expira; retomada revalida. Loading, vazio, erro/retry e continuação visíveis. Cards compactos usam capa autorizada; claro/escuro, 320px/texto200% e componentes Flow. Flows inclui leitura de imagens revalidada e memória de widget, sem URLs no cache global.

Rotas: `/flows` abre lista vertical; `/flows/{experienceId}` seleciona item do carrossel; `/experiences/{id}` abre detalhe; `/experiences/{id}/flow` é gestão contextual do criador. Não há link HTTPS de compartilhamento aprovado neste ciclo. Ver [Flows](flows.md), [ADR0010](../decisions/0010-explore-flows-exposure-media.md) e [relatório PR-05](../architecture/pr-05-completion-report.md).
