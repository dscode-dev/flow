# Autenticação mobile — PR-01.B

Implementação Flutter local sobre os contratos PR-01.A. Backend/OpenAPI não alterados. Decisão [ADR 0008](../decisions/0008-mobile-auth-sessions.md); ver também [integração exata](identity-mobile-integration.md).

## Telas e estados

Welcome e escolha PHONE/GOOGLE/APPLE na mesma tela, telefone com código de país editável (+55 inicial), OTP único com autofill/expiração/cooldown/reenvio manual, onboarding mínimo e shell autenticado explicitamente de desenvolvimento. Não há Home fictícia, senha, convidado, e-mail auth, analytics, localização ou contatos. Flow em texto é identificação provisória, não logo aprovado. Ícones de launcher continuam scaffold e são gate de lançamento.

Initializing/refreshing, unauthenticated, authenticating, challengePending, onboardingRequired, authenticated, sessionExpired, restricted e erro de armazenamento/rede têm comportamento central. Erros usam code e mensagem local, com request_id sanitizado para suporte; nunca mostram mensagens/payloads externos. Não expomos distinção cadastro/login nem existência de conta. 429 respeita Retry-After; o prazo conservador não garante liberação de quotas horárias/diárias. Envio de SMS aceito não é confirmação de entrega. Timeout da prova ou refresh nunca gera repetição automática.

Layout Material 3, claro/escuro, gradiente azul/roxo/rosa discreto, largura máxima 440, scroll/teclado/SafeArea, botões de 48dp, labels/autofill e anúncios semânticos de erros/processamento. Indicador fica estático com reduzir movimento. Testes cobrem texto 200%, largura 320 e teclado; VoiceOver/TalkBack físicos ainda precisam de homologação.

## Configuração externa necessária

| Item | Configuração exigida / situação atual |
| --- | --- |
| SDK | Flutter 3.47.8 / Dart 3.13.7, .fvmrc e pubspec.lock; SDK global não atualizado |
| API | `FLOW_ENV=development|test|production`, `API_BASE_URL` com `/` final; produção exige HTTPS. Origem pública/DNS/TLS ainda não fornecidos |
| Android | applicationId final, client OAuth Android correspondente ao package e SHA-1 da chave debug/release; ainda `com.example.flow_mobile`. Credenciais de assinatura não pertencem ao git |
| Google | `GOOGLE_SERVER_CLIENT_ID` (OAuth Web do backend); no iOS também `GOOGLE_IOS_CLIENT_ID`. Backend `GOOGLE_CLIENT_IDS` contém exatamente audiences/azp aprovados para os clientes reais. Sem Firebase Auth ou dependência de projeto Firebase |
| Callback Google iOS | `ios/Flutter/Auth.local.xcconfig` ignorado, com `FLOW_GOOGLE_REVERSED_CLIENT_ID` aprovado. Info.plist usa esse build setting. Corresponder ao client iOS; valor padrão vazio; preflight nativo recusa IDs/callback ausentes antes de abrir o SDK |
| Apple iOS | bundle final (hoje `com.example.flowMobile`), equipe/App ID com Sign in with Apple e provisioning compatível. Entitlement declarado; ativar `APPLE_SIGN_IN_ENABLED=true` somente depois de configurar. Backend `APPLE_CLIENT_IDS` com audience nativa aprovada. Nenhuma chave .p8 no app |
| Apple Android | indisponível neste ciclo; exigiria Service ID, domínio/callback HTTPS verificados e fluxo próprio aprovado. Nenhum callback inventado |
| SMS | Twilio Verify configurado somente no backend: ACCOUNT_SID/AUTH_TOKEN/VERIFY_SERVICE_SID, Geo Permissions e orçamento/quotas. Nenhum segredo SMS no Flutter; delivery real não foi homologado |
| Marca | logo oficial, ícones finais e validação visual de produto pendentes |
| Jurídico | URLs HTTPS reais verificadas e aprovadas em `TERMS_URL`/`PRIVACY_URL`, com `LEGAL_LINKS_APPROVED=true`; sem isso apenas texto de indisponibilidade, sem links falsos. Sem checkbox que simule aceite. Gate de publicação com produto/privacidade |

Não ativar providers com placeholders. Dart defines de client IDs/origem não são segredos. Não passar tokens, Twilio auth token ou chaves privadas como defines. Não há bypass debug de autenticação.

## Execução e homologação física (não executadas)

1. Usar Flutter 3.47.8 (`fvm flutter` se disponível, ou SDK isolado). Na raiz, `make env` preserva configuração existente e `make up` inicia backend/migrations. Preencher os provedores no ambiente de homologação conforme PR-01.A, sem publicar `.env`.
2. Aprovar applicationId/bundle, client IDs e assinatura; no Android obter SHA-1 da chave efetiva com `./gradlew signingReport` dentro de android. Registrar cliente Android correspondente e Web server ID no console Google Cloud. No iOS registrar client ID/bundle e reversed client ID no arquivo local acima; provisionar capability Apple em Xcode/Developer.
3. Obter IDs de dispositivos com `flutter devices`. No Android USB local, `adb reverse tcp:18080 tcp:18080` permite API `http://127.0.0.1:18080/` apenas debug. Emulador usa `http://10.0.2.2:18080/`. Cleartext está autorizado só no manifest debug. iPhone físico usa API HTTPS acessível com certificado confiável; não desabilitar ATS/validação TLS. Confirmar a porta do ambiente se sobrescrita.
4. Em `apps/mobile`, executar `flutter run -d <dispositivo> --dart-define=FLOW_ENV=development --dart-define=API_BASE_URL=<origem-real-com-barra> --dart-define=GOOGLE_SERVER_CLIENT_ID=<cliente-web-aprovado>`; no iOS adicionar `--dart-define=GOOGLE_IOS_CLIENT_ID=<cliente-ios-aprovado> --dart-define=APPLE_SIGN_IN_ENABLED=true`. Configurar links legais aprovados somente após revisão. Nenhum comando contém segredo de servidor.
5. PHONE: número de teste autorizado; observar recebimento real, incorreto/expirado, cooldown e novo desafio. Respeitar quotas/custo; não testar com envios repetidos indiscriminadamente. Cancelar Google/Apple, testar sucesso em ambos os sistemas suportados, negar permissão e testar credencial revogada. Apple Android deve informar indisponibilidade.
6. Primeiro login abre perfil, conflito de handle mantém formulário, sucesso abre shell. Retorno por método vinculado usa o mesmo usuário sem pedir telefone extra. Encerrar e reabrir antes de completar retoma onboarding via refresh. Reabrir depois de concluir mantém perfil confirmado. Não interpretar e-mail relay como conta nova/igual.
7. Aguardar TTL de access, observar renovação sem relogar; interromper rede durante refresh exige autenticar novamente, sem retry antigo. Sair offline limpa local e informa revogação não confirmada. Revogar sessão em outro dispositivo e voltar ao app deve invalidá-la; revogar autorização Apple nas configurações deve encerrar Flow no retorno (webhook também precisa endpoint HTTPS configurado).
8. VoiceOver/TalkBack, texto ampliado, temas, reduzir movimento, teclado, rotação e erro de rede em todas as telas. Deep link `/app` antes do login não mostra conteúdo, onboarding é obrigatório quando indicado; URLs externas/returnTo não são destinos de navegação.

Build de simulador/test doubles não comprova SMS, consentimento OAuth, assinatura de distribuição nem entrega de webhook. Registrar aparelho/OS/ambiente e resultado de cada cenário quando realmente executado, sem capturar OTP/tokens/telefone/e-mail nos relatórios.
