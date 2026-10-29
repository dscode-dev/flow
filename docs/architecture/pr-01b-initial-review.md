# Revisão inicial — PR-01.B

29/10/2026. Branch main, HEAD `76e1daf1eafcdc90f6e4464bc171e22939b4a946`, workspace inicialmente limpo. Sem AGENTS.md aplicável. Lidos relatório PR-01.A, integração mobile, OpenAPI e implementação Go de desafios/verificação, base Flutter, manifests Android, Info.plist e entitlements iOS.

Flutter é apenas scaffold: Riverpod, go_router, Dio, SecureStore, tema Material 3; nenhuma autenticação funcional. Somente ícones gerados pelo scaffold; não há logo Flow aprovado. IDs Android/iOS ainda são com.example. Nenhuma credencial de provedores ou URL legal aprovada foi fornecida. Não converter placeholders em configuração final.

Backend é autoridade: login uniforme, nonce novo single-use, Apple nonce já SHA-256, onboarding_required, refresh rotativo sem tolerância a replay. Nenhuma mudança de contrato necessária.

Incompatibilidade identificada: google_sign_in 7.2.0 aceita nonce na inicialização única do singleton, não em authenticate. Reutilizar esse nonce ou reinicializar o singleton viola as regras. O adapter usará instância nova da implementação oficial GoogleSignInAndroid/GoogleSignInIOS por tentativa, inicializada exatamente uma vez com o nonce do servidor, com tentativas serializadas e limpeza nativa. São pacotes federados oficiais flutter.dev, sem fork, fluxo web ou remoção da validação. API de plataforma fica confinada à fronteira e testável. Revisar esta decisão ao atualizar os SDKs.

Fontes consultadas: [Google/migração](https://github.com/flutter/packages/blob/main/packages/google_sign_in/google_sign_in/MIGRATION.md), [API singleton](https://pub.dev/documentation/google_sign_in/latest/google_sign_in/GoogleSignIn/initialize.html), [Android oficial](https://github.com/flutter/packages/tree/main/packages/google_sign_in/google_sign_in_android), [iOS oficial](https://github.com/flutter/packages/tree/main/packages/google_sign_in/google_sign_in_ios), [Apple 8.2.0](https://pub.dev/packages/sign_in_with_apple). Não usar perfis/e-mails externos como identidade Flow.

Apple neste PR é nativo iOS. Android informa indisponibilidade; não existe Service ID/callback web aprovado. Capacidade Apple será declarada, mas provisionamento depende do proprietário. Login real, SMS e revogação externa exigem homologação física posterior.
