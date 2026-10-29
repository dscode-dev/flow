# ADR 0006 — Provas externas, contas internas e sessões opacas

Status: aceito. Data: 28/10/2026.

Decisão: exatamente PHONE, GOOGLE e APPLE. Credencial verificada resolve `(provider,provider_subject)` único, nunca e-mail. Subject PHONE é HMAC-SHA256 da representação E.164, com chave de 32 bytes externa ao banco. Perfis não recebem e-mail, nome ou foto de provedor automaticamente. Cadastro e login retornam o mesmo modelo com onboarding explícito. Sem senha, reset, merge automático ou recuperação por atributos de perfil.

Google/Apple usam ID tokens RS256, chaves públicas em URLs fixas confiáveis, issuer/audience aprovados, exp/iat e nonce obrigatório. Uma challenge do backend liga provedor, finalidade e sessão quando aplicável. Cada prova cria um único efeito transacional. Google aceita audiences/clientes Android/iOS/web explicitamente aprovados, inclusive `azp` quando presente; não há wildcard. Apple usa o token nativo, sem troca de authorization code pelo backend neste fluxo. E-mail privado não define identidade; nome ausente em login posterior é irrelevante.

Sessões Flow usam access opaco aleatório de 256 bits (TTL padrão 10 minutos), refresh opaco de 256 bits com seletor UUID, expiração absoluta padrão 30 dias e rotação estrita. SHA-256 armazena segredos de alta entropia; comparações de refresh usam tempo constante. Não existe JWT Flow, protocolo criptográfico próprio ou token de provedor persistido. A sessão é a família de refresh; histórico de seletores usados permite detectar replay e revogar toda a família. Sem grace window: cliente deve serializar refresh e não repetir credencial antiga em timeout ambíguo.

PostgreSQL é autoridade para cada acesso protegido, status da conta e revogação. Quotas também usam UPSERT transacional PostgreSQL, com ordenação de buckets. Redis não armazena autoridade nem remove controles se cair. A readiness global PR-00 continua 503 durante queda Redis; requisições já direcionadas ao processo ainda verificam Identity pelo banco, sem fail-open. Banco indisponível resulta em 503, nunca autorização por cache.

Lock de challenge → advisory lock do provider/subject → usuário → sessão → refresh é a ordem de consumo. Criação/resend PHONE serializa por referência telefônica antes de tocar desafios anteriores e antes de lock de usuário. Unique constraints são a defesa final. Usuário é lock comum para vínculo/unlink, sessão e onboarding, evitando duas remoções simultâneas da última identidade.

Vínculo exige sessão válida, prova independente da identidade nova e autenticação nos últimos cinco minutos. Reautenticação requer prova de identidade já vinculada. Refresh não renova essa janela. Unlink conserva outro método ativo e configurado; ownership revogado fica reservado como tombstone, impedindo transferência silenciosa. Repetir vínculo do mesmo dono não duplica efeitos. Recuperação sem qualquer método disponível é escalada, sem promessa de restauração automática.

Apple server notifications assinadas tratam consent-revoked/account-deleted, revogando identidade e sessões Flow. Notificação de exclusão Apple não declara eliminação dos dados da conta Flow. Relay habilitado/desabilitado não altera autenticação. Replay é deduplicado por jti; payload assinado, issuer/audience e janela de emissão são verificados, sem exigir exp ausente no formato documentado.

Alternativas rejeitadas: JWT local com revogação apenas eventual, Redis como fonte única, merge por e-mail, confiar em device ID do cliente, replay de refresh tolerado silenciosamente e callbacks contendo bearer em URL.

Referências primárias: [Google OIDC](https://developers.google.com/identity/openid-connect/openid-connect), [identidade Apple](https://developer.apple.com/documentation/signinwithapple/verifying-a-user), [mudanças de conta Apple](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts). As regras adicionais de TTL, quotas, locks e retenção são decisões locais do Flow.
