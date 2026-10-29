# Relatório de execução — PR-01.B

29/10/2026. Implementação técnica local entregue; configuração e homologação externas, marca final e aprovação de URLs legais pendentes. Nenhum commit, push, merge ou deploy.

## 1. Estado inicial

Branch `main`, rastreando origin/main, HEAD `76e1daf1eafcdc90f6e4464bc171e22939b4a946`; workspace limpo. HEAD/branch preservados. Auditoria em [revisão inicial](pr-01b-initial-review.md). Contratos Go/OpenAPI e relatório PR-01.A lidos antes das alterações; nenhum arquivo backend/contracts modificado.

## 2. Arquivos criados e modificados

- **Criados — autenticação:** `apps/mobile/lib/core/auth/{models,identity_api,social_provider}.dart`, `lib/features/auth/{auth_screens,legal_links}.dart`, `lib/features/onboarding/onboarding_screen.dart`.
- **Modificados — app:** `lib/core/auth/auth_state.dart`, `lib/core/navigation/router.dart`, `lib/app.dart`, `lib/design/flow_theme.dart`. Riverpod, Dio e SecureStore existentes preservados; sem nova biblioteca de estado/rede. pubspec.yaml e pubspec.lock com plugins oficiais/mantidos e launcher.
- **Nativos:** Android debug AndroidManifest.xml permite HTTP somente debug. iOS Runner/AppDelegate.swift verifica callback Google sem abrir SDK; Info.plist, Runner.entitlements, Flutter/{Auth,Debug,Release}.xcconfig. Auth.local.xcconfig ignorado no .gitignore. Dois Package.resolved do workspace/projeto fixam dependências Swift reais (GoogleSignIn iOS 9.2.0); nenhum ID final/secret de provedor inserido.
- **Testes:** `test/{auth_controller,identity_api,social_provider}_test.dart`, `test/support/auth_fakes.dart` criados; widget_test.dart atualizado. Makefile mobile-check passa a executar a suíte inteira, também usada pela CI existente.
- **Documentação:** este relatório, revisão inicial, ADR 0008 e features/mobile-authentication.md criados. READMEs raiz/mobile, system-overview, product-scope, features/README, identity-mobile-integration, privacy/data-governance e admin-capabilities atualizados.

## 3. Telas e interações

Welcome com três métodos; telefone com código de país +55 editável e normalização E.164, OTP com autofill/expiração/cooldown/resend manual, feedback de quota/rede/prova, onboarding display_name/handle e shell autenticado identificado como desenvolvimento. Bootstrap, processamento, restauração, sessão expirada, restrição e erro de armazenamento têm UI. Claro/escuro, scroll/teclado, texto ampliado, labels, alvos 48dp e indicador estático ao reduzir movimento. Sem páginas de produto fictícias, senha, guest, contatos ou localização. Sem inventar logo: Flow aparece em texto; ícones ainda scaffold.

## 4. Integrações de provedores

PHONE usa challenges/verify reais Go, com finalidade login; não valida OTP localmente nem afirma entrega de SMS. Google usa pacotes oficiais google_sign_in 7.2.0 / Android 7.2.18 / iOS 6.3.8: uma instância federada por tentativa resolve o nonce fixo do singleton, sem reinicializá-lo nem reduzir segurança do backend. Preflight detecta configuração/callback ausentes. ID token exato segue para o endpoint Go; cancelamento distinto de falha.

Apple usa sign_in_with_apple 8.2.0 nativo iOS, nonce final sem hash duplo, state aleatório conferido e sem scopes adicionais. Não depende de nome/e-mail ou authorizationCode. CredentialState é consultado na restauração/retorno para sessões Apple; revoked/notFound encerra sessão Flow. Android informa indisponibilidade antes de solicitar challenge; não há fluxo web fictício. Não houve login real de provedor nem entrega SMS observados.

## 5. Sessão e refresh

AuthController único; access/perfil só em memória, refresh/metadados mínimos em uma chave segura. Fila de escrita e geração impedem updates antigos após logout/nova sessão. Refresh single-flight com journal persistido sem segredo antigo antes da requisição; gravação nova termina antes de liberar requests. Timeout/crash/rotação ambígua exige autenticar novamente, nunca retry do refresh antigo. 401 atrasado usa rotação já confirmada; GET pode repetir uma vez, escrita não repete automaticamente. Segundo 401, expiração absoluta ou restrição fecham a sessão. Logout tenta revogação e limpa local mesmo sem rede, informando quando não houve confirmação remota. Falha de limpeza bloqueia novo login. Saída/dispose cancelam requests Dio.

## 6. Navegação e onboarding

Router responde ao estado, sem navegação em interceptors ou callback de login. Bootstrap sem perfil não mostra área protegida. Revalidação com perfil conhecido mantém formulário/tela, com envios protegidos aguardando a sessão. Único destino protegido aprovado: `/app`; não aceitamos returnTo externo. Backend onboarding_required decide primeiro acesso/retorno. Sucesso do PATCH é necessário para concluir; conflitos mantêm dados, GET permite reconciliar perfil já salvo. Reinício restaura por refresh e retoma onboarding quando exigido. Vínculo/reautenticação continuam separados arquiteturalmente e sem UI neste ciclo.

## 7. Verificações realmente executadas

| Check | Resultado |
| --- | --- |
| SDK isolado | Flutter 3.47.8 / Dart 3.13.7 em /private/tmp; global 3.41.9 preservado |
| `make mobile-check FLUTTER=/private/tmp/flow-flutter-3.47.8/bin/flutter` | Passou: lockfile obrigatório, flutter analyze sem issues, **40 testes** |
| Sessões | Restore, corrupção/journal interrompido, storage read/write/clear failure, rotação concorrente, persistência antes de novo access, 401 tardio, escrita sem retry, timeout, expiração absoluta, revogação, logout offline/atrasado, resposta antiga sem reviver sessão |
| Fluxos/SDK boundaries | Nonce novo/exato, state Apple sem hash extra, cancelamento/falhas, callback iOS ausente, ausência de nome/e-mail, OTP/cooldown/429/expiração, onboarding confirmado/retomado, guards e envelopes HTTP |
| Widgets/acessibilidade | Welcome/telefone/OTP/onboarding/shell; texto 200%, largura 320, teclado, temas; guidelines de alvo/label/contraste na welcome |
| Android final | `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:18080/` passou; build/app/outputs/flutter-apk/app-debug.apk |
| iOS final | `flutter build ios --simulator --debug --dart-define=API_BASE_URL=https://localhost/` passou, Xcode/SwiftPM; build/ios/iphonesimulator/Runner.app, sem assinatura/aparelho |
| Formatação/diff | Dart format e git diff --check passaram |

Dublês existem somente em test e nas fronteiras injetadas dos SDKs/HTTP/armazenamento. Nenhum mock de autenticação em produção. Builds usam origens de verificação; não comprovam conectividade ou login externo. Não executamos testes físicos, SMS/OAuth/webhooks reais, distribuição assinada ou nova suíte backend (código Go inalterado).

## 8. Configuração externa faltante

ApplicationId/bundle finais, equipe/certificados/provisioning; client OAuth Android + SHA-1 e Web server ID; client iOS + reversed client ID; audiences/azp reais no backend; capability Apple/App ID/audience; origem API HTTPS/DNS/TLS; Twilio Verify/Geo Permissions/orçamento; logo/ícones aprovados; URLs de termos/privacidade revisadas. Nenhum Service ID/domínio/callback Apple Android foi inventado. Defaults de métodos sem configuração falham explicitamente.

## 9. Validação manual física

[Roteiro exato e defines](../features/mobile-authentication.md#execução-e-homologação-física-não-executadas): configurar providers e IDs aprovados, subir API, identificar dispositivo com flutter devices, selecionar origem alcançável (Android USB pode usar adb reverse somente debug), executar flutter run com client IDs públicos, testar sucesso/cancelamento/expiração/reenvio, restore antes/depois do onboarding, refresh interrompido, logout offline, revogação em outro aparelho/Apple e VoiceOver/TalkBack. iPhone exige TLS confiável e provisioning; não desabilitar ATS. Registrar resultados reais sem segredos/PII. Todas essas validações físicas permanecem pendentes.

## 10. Privacidade e administração

Inventário mobile documenta telefone/OTP transitórios, prova externa sem perfil social, refresh/identificador Apple criptografados, retenção local limitada à sessão, limpeza e ausência de analytics/permissões novas. ADM-013 descreve diagnóstico categórico, request_id, falha de storage/refresh, quota/configuração e limites de suporte. Nenhuma UI/API admin criada, nenhum segredo em tickets/logs e nenhuma declaração de conformidade LGPD.

## 11. Pendências e limites

Sem falhas conhecidas nos checks locais finais. Acoplamento às APIs federadas Google exige revisão em upgrades; SDK/navegação/Keychain reais ainda dependem da homologação descrita. Logo oficial ausente impede validar a identidade visual final; IDs/ícones de scaffold impedem distribuição. Aceite jurídico/produto e homologação externa continuam sob responsabilidade dos proprietários. Apple web Android está fora do escopo nativo aprovado neste ciclo; vínculo/configurações de conta e páginas de produto pertencem a ciclos futuros.

## 12. Status

**Implementação técnica local concluída, PR-01.B com pendências externas para o aceite integral.** Critérios de código, testes, builds disponíveis e documentação atendidos; marca oficial, configuração e observação de sucesso em provedores/aparelhos ainda não podem ser declarados concluídos. Mudanças disponíveis no workspace para revisão; sem staging/commit/push/merge/deploy.
