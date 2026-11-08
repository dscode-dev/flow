# Revisão inicial — PR-02.B

07/11/2026, America/Recife. Branch `main`, HEAD `92a6ada32c0bfd6a7b66590447034accd1d91a84`. Workspace já continha alterações de SDK persistente, Personal Team iOS e API local para iPhone, preservadas. Nenhum staging, commit, push, merge ou deploy autorizado.

Modificados no início: `.github/workflows/ci.yaml`, `.gitignore`, `Makefile`, `README.md`, `apps/mobile/README.md`, `apps/mobile/ios/Flutter/Auth.xcconfig`, `apps/mobile/ios/Runner.xcodeproj/project.pbxproj`, `apps/mobile/ios/Runner/Info.plist`, `scripts/auth-readiness.py`, `scripts/test_auth_readiness.py`.

Não rastreados no início: `.flutter-version`, `flutterw`, `apps/mobile/ios/Runner/RunnerPersonal.entitlements`, `infra/compose/mobile-local.yaml`, `scripts/mobile-config.py`, `scripts/mobile-local.py`, `scripts/test_mobile_config.py`, `scripts/test_mobile_local.py`. Configurações/segredos locais já ignorados.

Inspecionados: relatório PR-02.A; contrato mobile; OpenAPI1.1.0/31 operações e schemas Input/Experience/página/catálogo/upload/READY; lifecycle/visibilidade e ADR0009; handlers/modelos/integração Go/S3; AuthController.authorized/refresh, Dio, router, testes PR-01; temas/tokens/componentes; registro administrativo, privacidade, Compose e SDKs.

Não existem permissions/can_edit, total/participantes, perfil público de organizador, endpoint de preview/validação ou signed GET. UI usa somente o contrato existente. PUT completo, ETag forte, criação idempotente com snapshot; PRIVATE só criador, PUBLIC/UNLISTED autenticados, histórico redigido. Sem Mapbox configurado/marca final. Nenhuma mudança do domínio/contrato produtivo Go foi necessária.

Dependências justificadas: timezone (IANA/DST), image_picker (galeria), image (orientação/metadados em isolate), UUID (idempotência; já transitiva). Fontes primárias: [timezone](https://pub.dev/packages/timezone), [image_picker](https://pub.dev/packages/image_picker), [orientação image](https://pub.dev/documentation/image/latest/image/bakeOrientation.html) e código das versões resolvidas. Sem outro cliente JSON, refresh ou framework; transporte S3 separado é exigência do contrato.
