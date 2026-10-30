# Fronteiras dos módulos

Estas fronteiras são de propriedade, não serviços deployáveis ou endpoints antecipados. Cada ciclo define casos de uso, esquema, autorização e contratos detalhados antes de implementá-los.

| Módulo | Responsabilidade e dados próprios | Dependências permitidas / limites |
| --- | --- | --- |
| Identity | Identidade, credenciais, sessões, autenticação | PR-01.A: conta, métodos, sessões e perfil mínimo/onboarding; não possui perfil social |
| Users | Perfil e preferências de apresentação | Referência opaca a Identity; não acessa credenciais |
| Experiences | Experiências físicas, agenda, ciclo de publicação e visibilidade | PR-02.A: autoria opaca via elegibilidade Identity (Users social futuro); Media por Bind transacional; não gerencia presença |
| Participation | Participação, capacidade, elegibilidade | Usa Experiences e contexto autorizado; decide regras transacionais |
| Discovery | Busca, recomendação e projeções | Consome projeções autorizadas; nunca amplia visibilidade |
| Radar | Descoberta geográfica e consentimento contextual | PostGIS; localização mínima necessária; sem rastreamento contínuo |
| Flows | Coleções e percursos contextuais | Referências autorizadas a experiências; sem duplicar identidade |
| Social | Publicações e interações sociais | Media e Users; regras de moderação e audiência |
| Event Space | Espaço contextual de uma experiência | Participation decide elegibilidade; retenção contextual explícita |
| Messaging | Conversas e mensagens | Identidade e elegibilidade; não usa P2P |
| Media | Metadados, processamento, audiência e integridade | PR-02.A: capas S3 reais verificadas e bindings; download depende da autorização Experience; sem P2P/social |
| Notifications | Preferências, entrega e tentativas | Consome eventos mínimos; nenhum payload sensível em push |
| Sponsorship | Patrocínio e exposição contextual | Separação de conteúdo patrocinado e autorização; sem perfilamento implícito |
| Privacy | Consentimentos, solicitações e eliminação | Coordena módulos por contratos; não cria depósito central de PII |
| Administration | Operações privilegiadas e trilha de auditoria | Autorizações explícitas por módulo/recurso; nunca acesso irrestrito por padrão |

Invariantes de segurança pertencem ao servidor. IDs externos não concedem acesso. Sem leitura direta de tabelas de outro módulo. Eventos de integração transportam o mínimo necessário; dados de projeção mantêm origem e estratégia de atualização/exclusão. Chamadas síncronas são preferidas quando uma invariante exige consistência imediata; eventos servem propagação pós-commit. Dependências circulares exigem rever a fronteira, não um broker adicional.

PR-00 entregou plataforma; PR-01 implementa Identity e perfil mínimo de primeiro acesso, sem gestão geral Users. PR-02.A acrescenta Experiences e Media mínimo, conforme ADR 0009; demais módulos continuam futuros. Nenhum endpoint adicional é inferido desta tabela.
