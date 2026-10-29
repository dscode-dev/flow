# PR-01.C — configuração e aceite da autenticação

Status: implementação local; homologação externa pendente. O proprietário confirmou que os identificadores, contas de provedores, domínio, URLs legais e ativos finais ainda serão criados. Nada neste documento aprova valores fictícios ou comprova sucesso externo.

## Configuração por ambiente e segredos

1. Aprovar applicationId/bundle e origem API por ambiente. Registrar a decisão, o responsável e os IDs públicos; manter contas/audiences/chaves separados entre desenvolvimento, homologação e produção.
2. Copiar `apps/mobile/config/auth.public.example.json` para `auth.public.local.json` na mesma pasta (ignorado no Git) e preencher apenas valores públicos aprovados. Build/run: `flutter run --dart-define-from-file=config/auth.public.local.json` em apps/mobile, selecionando explicitamente o dispositivo. Produção exige FLOW_ENV=production e HTTPS. O exemplo vazio falha deliberadamente; não é configuração utilizável.
3. No servidor, injetar DATABASE_URL/REDIS_URL/RABBITMQ_URL e IDENTITY_HMAC_KEY/TWILIO_* pelo mecanismo seguro do ambiente escolhido. GOOGLE_CLIENT_IDS/APPLE_CLIENT_IDS são allowlists públicas do servidor. Não usar `source` em arquivo recebido, não imprimir env/Compose config interpolado nem colocar credenciais em argv, logs, JSON público ou Git. Compose/.env atual é apenas desenvolvimento local; deploy/secret manager ainda não foi selecionado nem provisionado.
4. HMAC precisa ser estável entre reinícios e instâncias do mesmo ambiente. Não gerar outra chave a cada deploy: isso quebraria lookup PHONE. Rotação exige plano explícito, janela e auditoria. Não compartilhar a chave local com produção.
5. Na raiz, `make auth-readiness` audita estrutura sem rede e sem mostrar valores. Alternativa: `python3 scripts/auth-readiness.py --public-config <json-publico> --server-env <arquivo-servidor> --json`. Ambiente do processo tem precedência, como no Compose. Exit 1 significa pendências; exit 0 comprova somente estrutura. Não colocar esse comando como gate verde de CI usando credenciais fictícias. Testes do auditor: `python3 -m unittest discover -s scripts -p test_auth_readiness.py`.

Nunca preencher exemplos com IDs aleatórios para obter verde. Um campo presente não prova configuração no console, acesso de rede, conteúdo jurídico, propriedade de domínio ou provisionamento.

## Android: ID e assinatura

Hoje applicationId/namespace são com.example.flow_mobile, MainActivity está no package correspondente. Ao aprovar o ID, atualizar coerentemente Gradle, pacote/caminho Kotlin e resolução da Activity no manifest. Não trocar só o package no console Google.

`cd apps/mobile/android && ./gradlew signingReport` mostra fingerprints das chaves efetivamente usadas. Em APK compilado, usar `apksigner verify --print-certs <apk>` do Android SDK para conferir SHA-1/SHA-256 e assinatura. Certificado debug local não é certificado de distribuição; CI/outra máquina pode usar outro debug keystore. Registrar ambos separadamente no cliente OAuth Android apropriado. Se Play App Signing for escolhido, conferir a chave de assinatura do app entregue pelo Play, além da upload key quando aplicável. Chave, senha e keystore não entram no Git.

Release ainda não tem signingConfig configurado. App ID final, chaves/certificados, estratégia de distribuição e metadados da loja são bloqueadores sob Mobile/Produto. Manifest principal proíbe backup; HTTP só foi liberado no manifest debug. Não habilitar cleartext no release.

## Google OAuth

Criar projeto/consentimento e clientes Android, iOS e Web para o backend no Google Cloud aprovado. Definir usuários de teste/audiência e configuração de consentimento aplicável; um app em teste não é prova de publicação/verificação. Não há Firebase Auth.

- Android identifica package e SHA-1 da assinatura efetiva. GOOGLE_SERVER_CLIENT_ID é o cliente Web; o SDK Credential Manager gerencia a interação nativa, sem callback web fictício.
- iOS: GOOGLE_IOS_CLIENT_ID corresponde ao bundle aprovado; GOOGLE_SERVER_CLIENT_ID corresponde ao backend. `ios/Flutter/Auth.local.xcconfig` contém `FLOW_GOOGLE_REVERSED_CLIENT_ID = <reversed-client-id-aprovado>`. Info.plist usa esse build setting. Preflight nativo confere a correspondência antes de abrir o SDK; ausência produz erro de configuração.
- Backend GOOGLE_CLIENT_IDS contém audiences/azp exatamente aprovados, sem wildcard. Verificar o fluxo real sem copiar JWT para decoders públicos/tickets. O contrato exige nonce novo do Go em cada tentativa. Adapter federado oficial novo por tentativa, inicializado uma vez, resolve a restrição do singleton 7.2.0; revisar essa API ao atualizar SDKs.
- Sem lightweight login, merge por e-mail ou escopos de contatos. Cancelamento é resultado distinto de falha/configuração. O token externo só é prova para Go, nunca bearer Flow.

Fonte: [configuração oficial Google iOS](https://developers.google.com/identity/sign-in/ios/start-integrating) e [integração Android oficial](https://pub.dev/packages/google_sign_in_android).

## Apple nativo e notificações

Criar App ID/bundle aprovado e configurar Sign in with Apple na equipe correta. Declarar capability no portal e gerar provisioning compatível; o entitlement já existe, mas não substitui essa configuração. Selecionar equipe no projeto Xcode. APPLE_SIGN_IN_ENABLED=true só após isso; APPLE_CLIENT_IDS no backend deve incluir a audience nativa correta.

Usar o nonce final do Go diretamente: já é SHA-256 hex. State aleatório é conferido. Nome/e-mail/relay e authorizationCode não identificam a conta Flow. Este fluxo nativo não exige Service ID, client secret ou chave .p8 no app; não provisionar code exchange sem contrato novo.

No App ID primário, configurar endpoint HTTPS real `/v1/auth/apple/notifications`, alcançável pela Apple, com TLS apropriado. Testar notificação assinada e deduplicação observando revogação Flow. O cliente agora também observa a notificação nativa de revogação em foreground, consulta CredentialState sem repassar subject/payload ao Flutter e encerra somente uma sessão Apple quando revogada/notFound. Restore/resume e a autoridade Go continuam como proteções adicionais.

Apple Android web permanece fora do fluxo aprovado: exigiria Service ID, domínio e callback verificados. Não há Universal/App Links obrigatórios para os fluxos nativos escolhidos; não inventar associated domains/assetlinks. Deep link interno `/app` é guardado, mas não comprova associação externa de domínio.

Fontes: [notificações Apple](https://developer.apple.com/help/account/capabilities/enabling-server-to-server-notifications), [revogação e CredentialState](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).

## Twilio Verify e ingress

Provisionar Account/Verify Service reais, conta habilitada para destinatários de homologação, Geo Permissions apenas para países aprovados, Fraud Guard, alertas de custo e orçamento operacional. Injetar SID/token/Service SID apenas no servidor. AUTH_* e SMS_* continuam limitados pelo Go/PostgreSQL, inclusive sem Redis. RiskCheck é habilitado pelo adapter; nunca desabilitá-lo para obter um teste aprovado.

Conferir janela de validade do serviço. Twilio pode reutilizar o mesmo código durante sua janela; Go usa challenge single-use, expiração própria e supersede no resend. Não prometer código diferente nem entrega com base no POST aceito. Registrar recebimento e VerificationCheck reais com número autorizado, sem colocar número/código nos artefatos. Aguardar cooldown e quotas; não aumentar limites para repetir testes.

API pública exige decisão de ingress: atualmente Go usa RemoteAddr e ignora X-Forwarded-For não confiável. Atrás de proxy, usuários podem compartilhar o bucket da origem do proxy. Antes de abrir tráfego, Infra/Segurança devem definir topologia, proxy confiável e limite no edge; não confiar globalmente em headers do cliente. HTTPS/TLS e injeção de segredos reais ainda não estão provisionados.

Fonte: [validade e limites Verify](https://www.twilio.com/docs/verify/api/rate-limits-and-timeouts), [proteções Verify](https://www.twilio.com/docs/verify/api/programmable-rate-limits).

## Marca e documentos legais

Produto/Design deve fornecer fonte aprovada do logo e ícones, variações claro/escuro, referência de aprovação e versão/checksum. Integrar somente esse material em Flutter, Android launcher/adaptive icons e iOS AppIcon; remover artefatos do scaffold após aprovação. Não usar imagem gerada ou logo copiado da internet. Texto Flow atual é identificação provisória.

Produto/Privacidade deve fornecer URLs reais de Termos e Política, com conteúdo aprovado e responsável. Conferir HTTPS, status, redirecionamentos e destino final no navegador do aparelho; somente depois definir TERMS_URL/PRIVACY_URL/LEGAL_LINKS_APPROVED=true. Não há URL nem texto jurídico final disponível nesta execução, portanto verificação de destinos está bloqueada. Inventário técnico não é política publicada nem declaração LGPD.

## Homologação do proprietário e evidência reproduzível

O [roteiro mobile](mobile-authentication.md#execução-e-homologação-física-não-executadas) continua aplicável. Executar em ambiente e contas de teste aprovados, Android e iPhone físicos, com IDs e assinatura efetivos. Nenhuma instalação no iPhone conectado foi feita nesta execução.

| Cenário | Verificação esperada / evidência sem segredos |
| --- | --- |
| PHONE novo/retorno | Pedido aceito, SMS realmente recebido, código incorreto/expirado rejeitado, cooldown/resend, login uniforme e mesmo usuário no retorno; IDs de request/cenário e horário |
| Google Android/iOS | SDK oficial abre conta correta, cancelar não autentica, nonce confere no servidor, sucesso/retorno/onboarding, erro de configuração não vira login |
| Apple iOS | Consentimento inicial e retorno sem nome, nonce/state corretos, cancelamento, revogação em foreground/retorno e notificação servidor; nenhuma inferência por relay |
| Onboarding | Nome/handle válidos, colisão/reserva, confirmação Go, retomada após fechar app antes/depois de salvar; nenhum perfil completo só local |
| Refresh | Restore, renovação por TTL, requests concorrentes sem replay, corte de rede/encerramento durante rotação exigindo login, ausência de reuso antigo |
| Logout | 204 revoga sessão e refresh; access expirado renova uma vez se seguro, depois revoga. 401 sozinho não comprova revogação. Offline/ambíguo limpa local e informa limitação |
| Suspensão/revogação | Operador autorizado suspende/revoga em ambiente de teste; cliente perde área protegida, sem contornar por outro método |
| Interrupções | Background/resume no OTP/SDK/onboarding, perda de rede e encerramento do processo; sem sessão fantasma nem envio duplicado |
| Nativo/acessibilidade | Keychain/Keystore, callback, guards/deep link, teclado, texto ampliado, VoiceOver/TalkBack, reduzir movimento; aparelho/OS/versão/hash do build |
| Release | IDs finais, artefatos assinados, certificados corretos, marca e links aprovados; CI do commit exato e ambiente/deploy autorizado |

Guardar ambiente, commit/hash do artefato, plataforma/OS, responsável, início/fim, resultado, request_id sanitizado e referência de evidência. Não guardar token/OTP/telefone/e-mail, cabeçalho Authorization ou dump de secure storage. Afirmar explicitamente se houve fixture: não anexar esse resultado como login real.

## Comandos locais e limites da evidência

- `make mobile-check`: lockfile, análise e testes Flutter; contrato real fica explicitamente skipped sem o bridge.
- `make identity-test`: Go HTTP/OpenAPI/PostgreSQL real, upstreams de fornecedores controlados; só flow_identity_test é recriado e Redis é restaurado.
- `make identity-mobile-contract FLUTTER=<sdk>/bin/flutter`: inicia bridge somente em binário `_test.go` com build tag integration; Flutter Dio/AuthController acessam API Go real e banco isolado, com provas OAuth/SMS de fixture. Testa cadastro/retorno, onboarding, restore, refresh concorrente/replay, logout com 401, falha de persistência e suspensão. Rotas `__fixture` não são compiladas nem registradas no backend de produção.
- `flutter test integration_test/auth_native_test.dart -d <simulador-limpo>` em apps/mobile: executa armazenamento seguro e guards/configuração ausente em OS real de simulador, sem chamar SMS/provedores. Não usar simulador/dispositivo com sessão existente; o teste exige registro inicialmente vazio. Não é homologação externa.
- Builds APK debug e iOS simulator são categoria de compilação; só executar emulador/simulador não comprova aparelhos físicos. CI remota é categoria separada e precisa do commit exato; mudanças locais não herdam verde do HEAD anterior.
