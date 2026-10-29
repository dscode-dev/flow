# Identity — PR-01.A

## Fronteiras e estado entregue

Identity implementa autenticação/registro por PHONE, GOOGLE e APPLE, perfil mínimo de primeiro acesso, onboarding, sessões, vínculo, desvínculo e revogação Apple. Não implementa senha, recuperação automática, CRUD Users, administração, social, eventos ou telas Flutter. Flow é implementação nova conforme ADR 0005. Go permanece na versão 1.27.3 do PR-00.

Código: `backend/internal/identity` contém casos de uso; `provider` concentra integrações externas e verificação criptográfica; `transport` trata HTTP/JSON e bearer. `cmd/api` injeta o módulo no router PR-00. Queries são sqlc/pgx, migração 00002 incremental. Nenhum mock é compilado em runtime. Test doubles HTTP estão somente em arquivos `_test.go`; a chave RSA em testdata é pública/exclusivamente de teste e nunca é carregada pela API.

## Dados e invariantes

Schema `identity`: users, profiles, reserved_handles, auth_identities, devices, sessions, refresh_credentials, access_credentials, challenges, rate_limits, audit_events e provider_notifications. `users.status` distingue active, suspended, disabled e deleted. Os três últimos negam acesso/refresh/login existente; não são comprovante de eliminação LGPD e não possuem API pública de mutação.

`(provider,provider_subject)` é único. PHONE usa referência HMAC E.164, OIDC usa sub verificado. Nenhuma identidade é transferida ou conta mesclada por metadados. Identidades revogadas mantêm reserva de ownership; reativação pelo mesmo dono exige sessão, autenticação recente e nova prova. Perda do único método precisa do processo conservador de suporte abaixo. Vínculo atômico não cria segunda conta.

Perfil contém somente display_name (NFC, trim, sem controles/caracteres de formatação invisíveis, até 80 caracteres), handle opcional até onboarding e avatar_ref nulo sem upload. Handle é trim/lowercase ASCII, começa com letra e tem 3–30 caracteres `[a-z0-9_]`; unique constraint e tabela de reserva impedem colisão e nomes operacionais iniciais. Não há reserva temporária por tela nem promessa de disponibilidade antes do commit. Onboarding só completa uma vez; repetição normalizada igual é idempotente e alteração posterior requer feature futura.

Device é registro novo do servidor a cada sessão, apenas platform android/ios, app_version e label opcional. Não aceita identificador cliente nem fingerprint. Há no máximo 10 sessões ativas por padrão, configurável até 20. Listagem traz todas as ativas dentro desse limite; created_at/id definem ordenação. last_used_at/last_seen_at são atualizados na renovação. Não são rastreamento contínuo de atividade.

## Provas e fronteiras de confiança

Criar challenge antes de solicitar credencial ao provedor. Purpose login é público; link/reauth estão ligados à sessão chamadora. Link exige prova recente tanto ao criar quanto ao consumir. Nonce é 256 bits, devolvido para uma tentativa, com digest armazenado; Apple já recebe o nonce hash em hexadecimal, que deve ser passado sem outro hash. O backend exige a mesma representação no claim assinado. Challenge expira, possui tentativas limitadas e só pode produzir um efeito transacional. Nunca aceitar provider_subject do cliente.

Google: JWKS fixo `https://www.googleapis.com/oauth2/v3/certs`, issuer Google permitido pela biblioteca OIDC, RS256, audiences/azp explicitamente aprovados, exp/iat (emissão até cinco minutos, tolerância futura 30 segundos), sub e nonce. Chaves são cacheadas/atualizadas pela biblioteca mantida; nenhuma URL de header JWT é usada. Apple: JWKS fixo `https://appleid.apple.com/auth/keys`, issuer `https://appleid.apple.com`, IDs de apps aprovados e mesmas verificações de validade/nonce. Não persiste e-mail, relay, nome, provider access token, provider refresh token ou authorization code.

Fluxo Apple selecionado: ID token nativo com nonce; o backend não recebe código, não realiza troca OAuth e não precisa de `.p8`, Team ID ou client secret para essa verificação. Para futuras operações de revogação de tokens Apple/conta ou outro fluxo com code exchange, a equipe deverá definir o ciclo e então fornecer Team ID, Key ID, chave `.p8`, client secret ES256 e requisitos Apple correspondentes. Não alegar essa integração externa como implementada nesta etapa.

Webhook `/v1/auth/apple/notifications` aceita somente JWS validado e deduplicado. O formato documentado não exige exp; há iss/aud/iat/jti, janela máxima de sete dias e validação do evento assinado. consent-revoked/account-deleted invalidam a identidade Apple e todas as sessões da conta Flow. Não apagam outra identidade ou perfil automaticamente. Eventos de relay não influenciam autorização. No PR-01.B, observar também credential-state changes nativas: revoked/notFound exigem limpar estado local e invalidar sessão quando possível, sem confiar somente no aparelho para enforcement. Transferência entre equipes Apple exige ciclo específico de migração de subject, sem merge automático.

## Sessões e concorrência

Access `fa_<segredo256>`; refresh `fr_<uuid>.<segredo256>`. Banco guarda SHA-256 dos segredos, seletores, família/sessão e expiração. Access padrão 10m, sessão absoluta 30d, sem sliding infinito. Cada refresh válido marca o seletor como usado e emite próximo par no mesmo commit. Segredo errado não revoga uma sessão alheia; segredo correto reutilizado revoga a família inteira. Access anterior pode continuar válido até seu TTL, mas qualquer revogação/status bloqueia imediatamente consultas posteriores ao commit, inclusive tokens novos da família. Requisições já em andamento podem ter sido autorizadas antes do commit.

PostgreSQL é obrigatório para validar cada bearer, status, quota e operação. Queda de Redis não permite acesso por cache nem remove quotas; readiness global continua refletindo Redis como dependência do PR-00. Sem banco, negar com temporarily_unavailable. Refresh não renova autenticação recente; reauth usa uma identidade já vinculada. Suspensão/disable/deleted prevalecem sobre prova externa válida. Ações de suporte/financeiras futuras não devem inferir autorização de um simples login SMS.

Unlink exige outro método configurado e não revogado; serialização por usuário impede remover os dois últimos em concorrência. A sessão Flow que iniciou a ação não é automaticamente apagada por unlink voluntário: a pessoa pode revogar sessões explicitamente. Mudança de consentimento Apple é diferente e revoga todas. IDs/client metadata não provam posse de credencial.

## Eventos e auditoria

Outbox grava atomicamente apenas identity.user.created, identity.provider.linked/unlinked e identity.session.created/revoked. Payload mínimo user_id, envelope v1; sem token, telefone, OTP ou e-mail. Atualização do padrão de event_type aceita fatos com segmentos como identity.session.created. Não foi inventado evento de suspensão sem operação implementada. Não há relay RabbitMQ neste ciclo: eventos estão duráveis na outbox, não declarados como publicados ao broker.

Auditoria de segurança persiste verificação negada, falha de entrega, criação/revogação/reauth de sessão, vínculo/desvínculo, onboarding e notificações. A ação/resultado/motivo são classificações estáveis, com IDs opacos e correlação; nenhum payload de provedor. Quotas representam indicadores agregados de abuso, sem criar registro de auditoria por cada request inválido. Logs HTTP guardam método/status/duração/correlação, sem URL/query/corpo/Authorization. Auditoria não é analytics nem trilha WORM já homologada; produção deve separar permissões e exportação protegida.

## Configuração e operação

`make env` gera IDENTITY_HMAC_KEY hexadecimal de 32 bytes somente quando ausente/vazia e preserva valor existente. API falha no startup com chave ausente/inválida. Esta chave determina lookup de telefone e pseudônimos de origem: manter backup protegido e não trocar arbitrariamente, pois isso impediria encontrar identidades PHONE existentes. Rotação exige migração/versionamento controlado e prova de posse, sem criação/merge automático. Produção injeta secret manager; não usar o gerador local como mecanismo de provisionamento de produção.

Google/Apple são opcionais enquanto sem client IDs; endpoints retornam provider_unavailable. Configuração parcial Twilio falha no startup. Variáveis, defaults e limites estão em `.env.example` e `identity/config.go`: AUTH_ACCESS_TTL 10m (1–15m), AUTH_SESSION_TTL 720h (1h–90d), AUTH_CHALLENGE_TTL 5m (1–10m), AUTH_RECENT_AUTH 5m (1–10m), AUTH_RESEND_COOLDOWN 60s (30s–10m), AUTH_OTP_ATTEMPTS 5 (1–5), AUTH_MAX_SESSIONS 10 (1–20), AUTH_ORIGIN_MINUTE 60 (1–1000), SMS_NUMBER_HOUR 3, SMS_ORIGIN_HOUR 5, SMS_GLOBAL_MINUTE 10 e SMS_GLOBAL_DAY 100. Últimos quatro são reservas de tentativas, não métricas de entrega.

Origem vem de RemoteAddr, IPv6 agrupado em /64, com HMAC separado de telefone. Cabeçalhos X-Forwarded-For não são confiados; atrás de proxy as quotas são compartilhadas pelo IP do proxy até existir contrato explícito de preservação de origem confiável. Planejar esse contrato no ingresso antes de abrir tráfego público; nunca habilitar confiança indiscriminada em headers. TLS termina em borda confiável na publicação; Compose permanece local.

Retenção tem comando real, sem processo ocioso: `go run ./cmd/identity-retention` a partir de backend com DATABASE_URL, ou `/app/identity-retention` na imagem. Executar diariamente por agendador operacional com papel autorizado e revisão de política; a API não executa exclusões em cada request. Janela técnica: access expirado/challenge/quota após 24h; notificações após oito dias; refresh e sessão até expiração absoluta +30d; device sem sessão e sem uso por 30d; auditoria 180d. Histórico de refresh não é removido só porque foi usado. O comando não exclui contas/identidades, reservas, outbox/inbox ou backups. Privacidade deve validar esses prazos antes de dados reais.

## Homologação externa e pré-requisitos do proprietário

- **SMS:** credenciais e settings da ADR 0007, número autorizado e observação explícita de recebimento + verificação. Nada foi enviado realmente nesta execução.
- **Google:** projeto/consent screen, OAuth client IDs reais por plataforma e audience esperada, certificados Android (incluindo assinatura de distribuição), bundle ID iOS e configuração SDK compatível com nonce. Informar lista explícita em GOOGLE_CLIENT_IDS; se azp diferir, incluir também o presenter aprovado. Sem client secret no Flutter.
- **Apple:** Apple Developer, Sign in with Apple no App ID real, bundle ID em APPLE_CLIENT_IDS; Service ID somente quando um fluxo web/Android correspondente for aprovado e configurado. Registrar HTTPS `/v1/auth/apple/notifications` no painel e validar uma notificação real. Sem chaves/IDs inventados. Não homologado contra conta real.

## Recuperação e suporte

Pessoa com outro método disponível entra por ele, reautentica e vincula método novo; não precisa confirmar telefone após login social. Sem qualquer método, abrir chamado por canal operacional definido pelo proprietário. Suporte não pode restaurar por e-mail, telefone alegado, nome, avatar, documentos enviados informalmente ou correspondência de metadados. Registrar caso, minimizar dados, escalar a segurança/privacidade e exigir procedimento de prova forte aprovado. Neste ciclo, não existe endpoint ou bypass de recuperação; se prova suficiente não existe, não prometer acesso. Reatribuir tombstones ou reativar conta deleted exige decisão formal, trilha e contrato futuro.

## Ameaças e controles

| Ameaça | Defesa atual | Limitação/gate |
| --- | --- | --- |
| Token de outro app/issuer/algoritmo | Chaves fixas, RS256, aud/azp/iss/exp/iat | Validar IDs reais do proprietário |
| Replay/login injection | Nonce por provedor/finalidade/sessão e consumo único | SDK do PR-01.B deve suportar nonce sem omiti-lo |
| Takeover por merge | Unique provider/sub e prova independente | Sem recuperação baseada em perfil |
| SMS pumping | BR por padrão, quotas duráveis/cooldown/teto diário + Verify | Custos e entregabilidade exigem homologação e alertas externos |
| SIM swap/reciclagem/interceptação | Limites, auditoria, sessões revogáveis | Risco residual inerente ao SMS; não autoriza privilégios sensíveis |
| Furto de refresh/replay | Hash, rotação e revogação de família | Credencial já entregue ao aparelho depende de armazenamento seguro |
| Corrida de OTP/vínculo/unlink | Locks e constraints transacionais reais | Testes de carga de produção pertencem ao ciclo operacional |
| Suspensão contornada/cache desatualizado | Estado autoritativo em cada bearer/refresh | Gate de readiness mantém política global PR-00 |
| Vazamento por observabilidade | Sem payload/PII, motivos categóricos | Revisar agentes externos e configuração de proxy/APM |
| Operação privilegiada abusiva | Sem admin API neste PR; registro de requisitos | MFA/segregação/auditoria protegida antes de admin real |

Validação local e integração mobile: [especificação PR-01.B](identity-mobile-integration.md), [relatório](../architecture/pr-01a-completion-report.md). As validações locais não equivalem a homologação comercial, segurança operacional completa ou conformidade LGPD.
