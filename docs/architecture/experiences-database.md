# Persistência Experiences / Media — migration 00003

Goose `00003_experiences_media.sql` adiciona schemas próprios sem alterar 00001/00002. Up cria Media mínimo antes de Experiences; Down remove FK binding, Experiences e Media e preserva Identity/outbox/PostGIS. Down apaga dados desses módulos: testar somente banco isolado; produção requer plano/backup próprio. Smoke recusa banco principal com contas, experiências, mídia ou integração existentes.

| Tabela/visão | Dados e invariantes | Índices/consistência |
| --- | --- | --- |
| experiences.categories | slug PK estável, label, enabled, sort_order, updated_at; 9 seeds | PK; FK preserva categorias históricas |
| experiences.experiences | UUIDv7, autor opaco, documento editável, lifecycle, moderation_status, instantes/fuso/ponto, capa, timestamps e versão | autor/created_at/id; público starts_at/id e categoria/starts_at/id parciais; GiST geography parcial público |
| experiences.idempotency | conta+UUID PK, hash SHA256 normalizado, ID e snapshot JSON, expiração 24h | expiry; atomicidade com criação |
| experiences.rate_limits | conta+operação+dia UTC PK, contador positivo | UPSERT sob lock de elegibilidade; limpeza >2d |
| experiences.publishing_restrictions | autor PK, blocked_until/reason_code mínimo | enforcement publish; API admin futura deve serializar com a mesma conta |
| experiences.audit_events | UUID, recurso/ator/ação/versão/request_id/UTC | unique recurso+versão; índice recurso/tempo/ID e tempo |
| experiences.documents | JSON derivado com coordenadas limitadas a6 casas, sem point binário no JSON; geography interno para filtros | view autoritativa sem duplicar estado; resposta HTTP selecionada por tipo Go |
| experiences.discovery | documentos PUBLIC/PUBLISHED/VISIBLE | view reconstruível; consulta aplica ends_at>agora e ST_DWithin sobre tabela indexada |
| media.uploads | dono opaco, idempotência/hash, staging/final keys, estado, tipo/tamanho esperado, expiração; READY inclui SHA256/dimensões/tamanho verificados | unique dono+key e object keys; cleanup expiry/id; checks MIME/5MiB/12MP |
| media.bindings | experience PK, upload FK, owner opaco, bound_at | índice media_id; FK Experience só integridade, operações via Media.Bind |
| media.audit_events | objeto/ator/ação/request_id/UTC, sem URL ou bytes | tempo; rastreia init/confirm/reject/orphan deletion |
| media.rate_limits | dono+dia UTC PK, contador positivo | quota upload independente, sem acessar tabelas Experiences |

Referências a Identity são UUIDs opacos, sem FK/leitura de tabelas do outro módulo. `identity.RequireCreator` é fronteira síncrona e mantém locks na transação do chamador. Não é nova autenticação. Ordem: conta -> sessão -> experiência -> categoria -> mídia; categoria não depende de conta/experiência. Criação e publicação usam essa ordem (Bind valida mídia antes do save), e futuros comandos administrativos precisam respeitá-la. Dados externos de pagamento/provedor/dispositivo não entram nesses schemas.

Checks SQL: enums/status-timestamps, limites de texto, capacidade positiva, fim>início/duração <=31d quando ambos presentes, publicação exige campos essenciais e ponto, READY exige metadata completa. Domínio valida IANA, URL, normalização e imutabilidade histórica; só queries do módulo devem escrever. Versão checked sob FOR UPDATE, If-Match e auditoria unique evitam update perdido/duplo evento. Não existe delete/restore de agregado por HTTP.

Queries em `backend/queries/{experiences,media}.sql`, geradas pelo sqlc 1.31.1 em dbgen. JSON é apenas a projeção e o documento de parâmetros tipado pelo serviço, não um depósito arbitrário: armazenamento primário usa colunas/constraints e ponto PostGIS. Nunca editar dbgen à mão. Reproduzir `make sqlc` e comparar o conteúdo gerado antes/depois.

Retenção/privacidade: [governança](../privacy/data-governance.md), [operação](../features/experiences.md). Outbox é da plataforma; consumo/retensão/replay precisam preservar invalidações e não restaurar conteúdo removido. Sem relay atual; cada alteração confirmada já é durável para integração futura.
