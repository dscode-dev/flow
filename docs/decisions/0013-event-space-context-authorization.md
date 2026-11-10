# ADR0013 — Event Space como contexto do Social

Status: aceita para implementação local PR-08. Data: 2026-11-09.

Cada Experience identifica um único espaço pelo seu próprio UUID. O espaço existe logicamente, sem criação assíncrona ou agregado/lifecycle duplicado. Configuração ausente equivale a ativo, sem moderadores/restrições adicionais. DRAFT não abre conteúdo.

Posts EVENT_SPACE exigem visibility SPACE e experience_id. PERSONAL/EXPERIENCE_PUBLIC mantêm as regras anteriores; nenhuma publicação antiga é convertida. Feeds públicos e perfis excluem EVENT_SPACE explicitamente, mesmo quando o observador é membro. Detalhe/comentários/mídia usam a mesma autorização contextual do Social.

Participation é a fonte de CONFIRMED e bloqueio; convites pendentes, interesse e PENDING não autorizam. Organizador e moderadores nomeados explicitamente podem moderar seu espaço. Moderadores precisam manter participação elegível. Revogação de participação desativa o papel; reconfirmação exige nova nomeação. Restrição local bloqueia interações, preserva leitura e revoga o papel. Bloqueios globais e restrições/contas ativas são reavaliados nas consultas.

Mutações: Identity/sessão → Experience → post → comentário/mídia. Participation e lifecycle usam a mesma Experience como ponto de serialização. Revalidação ocorre após o lock e antes de consultar recibos idempotentes contextuais. Uma mutação que aguardava remoção deve observar o novo estado. Operações já concluídas antes da revogação não são desfeitas.

PUBLISHED permite escrita antes e durante o encontro até ends_at. ENDED é derivado, somente leitura; CANCELLED/ARCHIVED preservam leitura para responsáveis e membros ainda elegíveis, sem reabertura. Moderação, denúncia e exclusão do próprio conteúdo são operações de segurança/direitos e continuam disponíveis conforme ACL, mesmo no histórico. Participation aceita remoção/bloqueio/desbloqueio de experiências anteriormente publicadas também no histórico; não reabre inscrições.

Galeria consulta os mesmos vínculos/objetos de mídia. Capacidades temporárias de 30s vinculam sessão/usuário/recurso; cada GET/range revalida a ACL atual. Cliente limpa dados em saída/background/sessão e em janela absoluta de até30s, sem polling. Não existe revogação remota de bytes já obtidos.

Ocultação local e contenção global são campos independentes. Restaurar localmente não desfaz retirada global/exclusão. Revisão local não encerra denúncia global. Audit/outbox transacionais contêm IDs e motivos categóricos, nunca body, telefone ou URL assinada. Consultas sensíveis ao resumo/listas/moderação são auditadas.

Consequências: uma política SQL central reduz caminhos alternativos de vazamento, sem N+1 de aplicação; as consultas correlacionadas ainda exigem medição com carga real. Novos papéis e configurações exigem governança de retenção e operação. Chat/presença/transporte realtime ficam para PR-09, que deverá consumir a mesma política e eventos de revogação, sem copiar audiência para claims duradouras.
