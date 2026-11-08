# ADR 0010 — Explorar, exposição de Flows e mídia revogável

Status: implementado localmente no PR-05, 08/11/2026. Homologação física/produção é independente. Complementa ADR0009 sem alterar a descoberta da Home/Radar.

## Contexto e decisão de audiência

Flow é a apresentação de uma Experience, não evento/social post separado. `experiences.flow_presentations` tem chave primária/foreign key Experience, configuração própria e ETag. Lifecycle, owner, ponto, agenda e categoria continuam no agregado existente.

PUBLIC/PUBLISHED/VISIBLE pode aparecer automaticamente quando possui mídia verificada e está na janela. PRIVATE nunca aparece. UNLISTED continua fora de Explorar/Home/Radar; somente Flows admite UNLISTED com `enabled=true` e consentimento público explícito do criador. A UI informa que título, agenda, local e mídia passam a ser descobertos publicamente. `unlisted_consent=true` é obrigatório em cada PUT que mantém essa exposição; primeiro aceite registra UTC/ator. Desativar limpa o consentimento e exige novo aceite ao reativar. Sem backfill de consentimento ou migração de audiência.

Cada mudança possui versão e evento com ator, UTC, request_id e snapshot de enabled/consentimento/visibilidade/refs de mídia. Ativos antigos UNLISTED não ganham exposição silenciosamente. Conteúdo cancelado, arquivado, encerrado, retido ou cujo criador está inativo/restrito sai da leitura elegível. A regra é SQL síncrona, sem cache de descoberta atrasando retirada. O GET detalhe continua seguindo a autorização Experiences, inclusive para UNLISTED opt-in; não ampliamos PRIVATE.

## Busca e ordenação

Explorar usa a visão PUBLIC existente e busca nativa PostgreSQL: tsvector armazenado, português/unaccent, GIN parcial e websearch_to_tsquery parametrizada. Ordem starts_at/id e cursor HMAC vinculado à conta/filtros. Flows prioriza LIVE, depois início e ID; não usa popularidade ou localização inferida. Região é filtro opcional escolhido, não pontuação de afinidade. Cursor fixa snapshot da ordem, enquanto elegibilidade/fim são reavaliados no relógio do servidor. Não há preço no modelo: ingresso externo não permite inferir gratuito/pago.

## Mídia e distribuição

Storage S3, quotas e autorizações POST reutilizados. `media.flow_assets` registra imagens/vídeos subordinados à mesma Experience/owner, idempotência, staging e estados. Confirmar enfileira trabalho persistido; worker Go do mesmo backend reivindica um item por vez via SKIP LOCKED/lease. Nenhum FFmpeg no handler.

FFprobe/FFmpeg somente com arquivos locais e protocolos file/pipe, timeout90s, stdout/stderr limitados, transcodificação H.264/AAC MP4 faststart, poster JPEG e remoção de metadados. MIME/tamanho declarados não bastam: leitura e inspeção reais e duração de entrada/saída até15s. Imagens passam pelo sanitizador existente. Container limita CPU/memória/pids/tmpfs e não recebe segredos Identity/SMS. Fencing/lock antes da escrita final impedem worker antigo de substituir resultado READY.

URLs de leitura são capacidades HMAC30s da API, vinculadas à sessão, conta e versões Experience/apresentação. Cada GET/range revalida sessão/conta e elegibilidade atuais e faz streaming S3; não há presigned GET irrevogável do S3, redirect, URL permanente ou download integral obrigatório de vídeo no app. Encerramento de autorização impede novas requisições; bytes já entregues e uma resposta em andamento não podem ser recuperados. HTTP tem prazo limitado; clientes encerram player na expiração/pausa. Essa limitação é explícita.

Sem P2P, streaming ao vivo, tracking de visualização ou analytics de reprodução. LIVE é fase da Experience. Links externos de compartilhamento não foram inventados: falta origem HTTPS/deep link aprovado. Administração e operação em docs/features/flows.md e docs/admin-capabilities.md.
