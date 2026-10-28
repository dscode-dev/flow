# Flow mobile

Base técnica Flutter 3.47.8 / Dart 3.13.7 com Material 3, Riverpod, go_router e Dio. Não contém autenticação ou funcionalidades legadas: o repositório fornecido está vazio.

Consulte o [README local](../../README.md) e o [workflow](../../docs/architecture/development-workflow.md) para inicialização, variáveis de ambiente, versões, links e testes físicos.

Executar `flutter pub get --enforce-lockfile`, `flutter analyze` e `flutter test test/widget_test.dart`. A aplicação exige `--dart-define=API_BASE_URL=https://SEU_HOST/`; configurações inválidas exibem estado seguro.

Ícones e IDs nativos são os padrões do scaffold, não marca aprovada. Signing, App Links/Universal Links, Mapbox e branding dependem de valores reais do produto. Não distribuir os padrões como release final.
