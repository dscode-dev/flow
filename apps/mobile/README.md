# Flow mobile

Base técnica Flutter 3.47.8 / Dart 3.13.7 com Material 3, Riverpod, go_router e Dio. Flow é implementação nova conforme ADR 0005. Backend Identity PR-01.A e integração de autenticação PR-01.B implementados; configuração e homologação externa pendentes.

Consulte o [README local](../../README.md) e o [workflow](../../docs/architecture/development-workflow.md) para inicialização, variáveis de ambiente, versões, links e testes físicos.

Executar `flutter pub get --enforce-lockfile`, `flutter analyze` e `flutter test`. A aplicação exige `--dart-define=API_BASE_URL=https://SEU_HOST/`; configurações inválidas exibem estado seguro.

Ícones e IDs nativos são os padrões do scaffold, não marca aprovada. Signing, App Links/Universal Links, Mapbox e branding dependem de valores reais do produto. Não distribuir os padrões como release final.


## Autenticação PR-01.B

Welcome, telefone/OTP, Google oficial, Apple nativo iOS, sessão segura, onboarding e shell de desenvolvimento implementados sobre PR-01.A. Sem credenciais reais configuradas não há login de sucesso. Leia [configuração e roteiro físico](../../docs/features/mobile-authentication.md) e [decisão de sessão/nonce](../../docs/decisions/0008-mobile-auth-sessions.md).

`flutter analyze`, `flutter test`, `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:18080/` e `flutter build ios --simulator --debug --dart-define=API_BASE_URL=https://localhost/` usam Flutter 3.47.8. A origem nos builds de verificação não comprova servidor acessível nem login. Configuração real exige IDs/callback/capability aprovados; tokens/chaves privadas não entram em dart-defines. Novas features protegidas usam AuthController.authorized, sem segundo mecanismo de refresh.


PR-01.C: configuração pública por ambiente em `config/auth.public.example.json` (valores deliberadamente vazios). Copiar para arquivo `.local.json` ignorado e preencher somente dados aprovados; usar `--dart-define-from-file=config/auth.public.local.json`. Nunca incluir chaves/segredos de servidor. [Readiness e configuração nativa](../../docs/features/authentication-release-readiness.md) e [evidência separada por categoria](../../docs/architecture/pr-01c-completion-report.md). `flutter test integration_test/auth_native_test.dart -d <simulador-limpo>` verifica armazenamento e guards sem autenticar com terceiros.
