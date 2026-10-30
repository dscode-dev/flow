# ADR 0009 — Experiências, visibilidade e capas verificadas

Status: aceito para implementação PR-02.A. Data: 29/10/2026.

## Decisão

Experience é um agregado físico único, proprietário de agenda, local e publicação, sem participação/capacidade ocupada, pagamento ou feed. Estados DRAFT/PUBLISHED/CANCELLED/ARCHIVED; UPCOMING/LIVE/ENDED são calculados sobre instantes UTC, preservando fuso IANA. Duração máxima 31 dias; publicação aceita experiência em andamento com fim futuro e início até 366 dias. O cliente resolve datas civis ambíguas/inexistentes em DST antes de enviar instantes UTC, sem adivinhação do servidor.

PUBLIC publicado é descobrível; UNLISTED publicado pode ser acessado diretamente por conta autenticada, sem membership; PRIVATE é apenas do criador até Participation/Invitations fornecer autorização explícita. Não indexar PRIVATE/UNLISTED. Uma visão PostgreSQL projeta o agregado autoritativo: cancelamento/moderação retiram da descoberta no mesmo commit, sem depender do relay. Cancelamento/arquivo mantêm identidade histórica, com detalhes sensíveis redigidos para terceiros. Conteúdo retido por moderação retorna 404 a terceiros.

Após publicar, agenda/fuso/local/endereço/venue/categoria/visibilidade/capacidade ficam imutáveis. Antes do fim, título/descrição/ticket/capa podem ser corrigidos; após o fim, só arquivar. Alterações relevantes de agenda/audiência exigirão política própria com Participation/Notifications; não há restore ou delete neste PR. Essa escolha conserva o significado histórico e evita ampliar audiência acidentalmente.

Sessão e conta são verificadas pelo middleware Identity. Escritas chamam `identity.RequireCreator` dentro da transação pgx: lock de conta e sessão, onboarding completo e status ativo; depois agregado e mídia. Nenhum SQL Experiences lê credenciais/tabelas Identity. Essa ordem serializa quotas, revogação, alterações e criação idempotente por conta. If-Match forte/versão previne update perdido; outbox, auditoria, idempotência e agregado confirmam juntos.

## Mídia

Não havia armazenamento implementado. Media passa a possuir uploads/metadados/bindings, com AWS SDK Go v2 e protocolo S3 SigV4 POST, sem acoplar Experiences a objetos arbitrários. Capacidade temporária de 5min fixa bucket, staging key, MIME e tamanho exato (1..5MiB). A confirmação lê bytes limitados, confere JPEG/PNG, dimensões <=4096 por lado/12MP e reencodifica sem metadados/trailer. Só então o servidor escreve `verified/` e marca READY. Essas chaves nunca são autorizadas para escrita do cliente. Uma autorização pode ser repetida até expirar; por isso validar apenas HEAD ou reutilizar a chave de upload como capa seria insuficiente. [Semântica S3 de repetição/sobrescrita](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html).

Bucket privado e leitura de capa por endpoint autenticado, autorizado pela Experience, com no-store. Não emitir URLs GET duradouras que mantenham acesso após cancelamento. O POST direto reduz tráfego de entrada na API; validação síncrona limitada evita worker especulativo e fornece associação pronta ao Flutter. Falha/timeout de storage retorna erro seguro; não existe fallback com URL fornecida pelo cliente. Reencodificação não faz classificação de conteúdo, OCR ou aprovação humana, nem preserva EXIF/orientação; cliente deve enviar imagem já orientada.

O ambiente local usa SeaweedFS 4.51 com autenticação S3 e volume próprio. [Release oficial](https://github.com/seaweedfs/seaweedfs/releases/tag/4.51) e [mini com credenciais/bucket](https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini). Isso prova protocolo real local e não seleciona infraestrutura produtiva. Nuvem requer provisionamento privado/TLS/IAM/retensão aprovados. [API de assinatura POST do SDK](https://github.com/aws/aws-sdk-go-v2/blob/main/service/s3/presign_post.go).

## Consequências e alternativas

Visão em vez de projeção assíncrona reduz complexidade inicial e é reconstruível integralmente. Índices geography/GiST permitem distância em metros; origem da consulta não é persistida. Consultas ordenam por agenda/ID, sem ranking ou ordenação por distância. Próximo ciclo pode materializar candidatos, mas precisa revalidar autorização/visibilidade autoritativamente e aplicar tombstones/versionamento.

Quotas PostgreSQL funcionam sem Redis. Chaves de criação têm retenção 24h e snapshot original, não estado mutável; após timeout o cliente repete a mesma chave e busca o ID. Cursor HMAC de 15min liga principal/filtros/limite; chave derivada com domínio próprio da HMAC configurada, sem uso como credencial. Não promete snapshot entre páginas: conteúdo e fase podem mudar.

Uma tabela de restrições e campo de moderação preparam enforcement, sem endpoints administrativos/autoaprovação manual. Operações futuras devem usar a mesma ordem de locks, auditoria e outbox; escrever tabelas fora do módulo não é contrato administrativo. Relay, DLQ e entrega externa continuam futuros; registrar na outbox não afirma publicar no RabbitMQ.
