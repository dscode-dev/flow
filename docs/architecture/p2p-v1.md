# P2P de mídia no Flow V1

Status: obrigatório para V1, **não implementado no PR-00**. Decisão em ADR 0003. Nenhum serviço, biblioteca WebRTC, canal ou cliente simulado foi adicionado.

Escopo exclusivo: imagens e vídeos de publicações sociais; duração máxima de vídeo **15 segundos**, validada no servidor durante ingestão. O cliente também valida para UX, sem ser a autoridade. Mensagens de chat, localização, notificações, credenciais e sincronização geral sempre passam por contratos próprios no backend.

Origem durável e fallback em storage S3 compatível. Conteúdo só pode ser anunciado entre peers após ingestão, verificação, moderação aplicável e registro da audiência. Um gateway Go controla signaling e permissões de sessão WebRTC mobile-to-mobile quando viável. Não publica diretório aberto de peers nem decide ACL no aparelho. STUN/TURN, terceiros e exposição de IP exigem avaliação de privacidade; evitar revelar candidatos de rede antes de autorização.

Servidor emite concessão curta vinculada a mídia, versão, destinatário, par e audiência; autorização para baixar não implica poder redistribuir. Negar concessão expirada, revogada, de conteúdo removido ou fora da audiência. Limitar tamanho, tipo, bytes e duração de sessão. Verificar manifesto/hash de chunks e hash final contra metadado confiável da origem; não aceitar integridade baseada só na declaração do peer. URLs S3 assinadas têm escopo e TTL mínimos.

Revogação interrompe novos handshakes e sessões ativas por controle do servidor, cancela transferências e expira caches conforme política. Conteúdo já entregue a outro dispositivo não pode ser tecnicamente recuperado com garantia: tratar como risco no consentimento e no modelo de audiência, não prometer apagamento remoto absoluto.

Sem atividade de peer em background. Ao perder foreground, fechar sessão, cancelando envio/recebimento e anúncio. Guardrails propostos para medir em aparelhos: no máximo 1 envio e 1 recebimento simultâneos, tentativa de conexão de até 5s antes do fallback, limite de bytes de mídia definido por variante antes da feature, opt-in para dados móveis, pausar em economia de bateria/temperatura elevada/rede medida. Valores finais dependem de resultados e decisão de produto; não há defaults ativos no PR-00.

Medir taxa útil de conexão, tempo ao primeiro byte, bytes de fallback, bateria, memória, CPU e custos TURN, sem registrar localização, candidatos ICE/IP ou IDs de audiência em métricas. Fallback é estado normal: falha de NAT, peer ausente ou rede inadequada não pode impedir acesso autorizado à origem. Não incentivar permanência em rede ou remunerar peers sem avaliação de produto/privacidade.
