# Flow mobile

PR-04: Radar em `/radar`, acessível pela Home, com SDK oficial Mapbox3.34.2, clustering nativo, filtros/preview e localização aproximada opcional. Sem token, somente Radar fica indisponível; não há mapa fictício. Adicionar MAPBOX_PUBLIC_ACCESS_TOKEN (`pk...`) ao arquivo público local ignorado e recompilar usando o wrapper. Nunca passar `sk...` ou credencial de download em Dart defines. [Configuração, privacidade e gate físico](../../docs/features/radar.md). Wrapper habilita o bypass Always do geolocator_apple SPM; Android usa Kotlin integrado do AGP9 compatível com Flutter3.47.8 e apenas COARSE_LOCATION.

PR-03: `/app` agora abre o Início com descoberta real, categorias contextuais, seleção manual de região aproximada e cards para os detalhes existentes. Gestão permanece em “Minhas experiências” (`/experiences`). Sem conteúdo público elegível, o vazio é esperado. [Critérios, privacidade, testes e limites](../../docs/features/home-discovery.md). `make mobile-local` na raiz atualiza a API antes de recompilar o app com o comando abaixo; não exige mudar a assinatura pessoal.

Para acesso temporário local pelo fluxo de telefone, consulte [modo de desenvolvimento](../../docs/features/development-phone-login.md). O app espera o challenge e a confirmação do código pelo servidor; não aceita credenciais nem cria sessão localmente. `make mobile-local` gera a flag visual correta no arquivo público local, sem incluir número/código.

PR-02.B: Minhas experiências, criação em etapas/revisão, rascunhos persistidos na API, edição, capas S3 verificadas, detalhes e lifecycle estão implementados. Rotas, contratos, concorrência, privacidade e configuração em [Experiences Flutter](../../docs/features/flutter-experiences.md). `../../flutterw test` inclui as suítes focadas; `make experiences-mobile-contract` na raiz verifica Flutter/Go/PostGIS/S3 reais em destinos isolados. Autenticação real e picker físico exigem homologação própria; não há conta mock no app.

Base técnica Flutter 3.47.8 / Dart 3.13.7 com Material 3, Riverpod, go_router e Dio. Flow é implementação nova conforme ADR 0005. Backend Identity PR-01.A e integração de autenticação PR-01.B implementados; configuração e homologação externa pendentes.

Use o SDK persistente do projeto, fixado em `.flutter-version`. Para testar no iPhone com o backend deste Mac, execute `make mobile-local` na raiz. Depois, dentro de `apps/mobile`:

```sh
../../flutterw pub get --enforce-lockfile
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

O arquivo local gerado contém a URL real do Mac, `FLOW_ENV=development` e Apple desativado para Personal Team. Mantenha Mac/iPhone na mesma rede e permita Rede Local quando solicitado. O wrapper valida a API antes de compilar/instalar e usa a tag oficial em `.toolchains/flutter-3.47.8`, ignorada pelo Git. Não depende de `/private/tmp` nem de `flutter` no PATH; a primeira instalação exige Git/rede, sem alterar o SDK global. Para outros comandos, use também `../../flutterw analyze`, `../../flutterw test` etc.

Consulte o [README local](../../README.md) e o [workflow](../../docs/architecture/development-workflow.md) para inicialização, variáveis de ambiente, versões, links e testes físicos.

Executar `../../flutterw pub get --enforce-lockfile`, `../../flutterw analyze` e `../../flutterw test`. A aplicação exige API_BASE_URL válido, preferencialmente via arquivo público de configuração por ambiente; configurações inválidas exibem estado seguro.

Ícones e IDs nativos são os padrões do scaffold, não marca aprovada. Signing, App Links/Universal Links, Mapbox e branding dependem de valores reais do produto. Não distribuir os padrões como release final.


## Autenticação PR-01.B

Para executar no iPhone com Personal Team gratuita, usar `ios/Flutter/Auth.local.xcconfig` (ignorado no Git) e manter `APPLE_SIGN_IN_ENABLED=false`:

```xcconfig
FLOW_CODE_SIGN_ENTITLEMENTS = Runner/RunnerPersonal.entitlements
FLOW_IOS_BUNDLE_IDENTIFIER = seu.identificador.unico
```

Substituir o identificador por um Bundle ID exclusivo da equipe; IDs locais gerados usam `dev.flow.local.p` seguido de sufixo aleatório e não são IDs aprovados de produção. Debug/Profile/Release usam os overrides locais. Defaults versionados continuam `Runner/Runner.entitlements` e `com.example.flowMobile`; ao configurar Apple com equipe/provisioning compatíveis, remover o override de entitlements e definir o Bundle ID aprovado. Selecionar a equipe em Runner > Signing & Capabilities no Xcode. O auditor resolve essas variáveis e recusa o modo Personal Team como configuração Apple pronta. Isso não é homologação/distribuição.

Welcome, telefone/OTP, Google oficial, Apple nativo iOS, sessão segura, onboarding e shell de desenvolvimento implementados sobre PR-01.A. Sem credenciais reais configuradas não há login de sucesso. Leia [configuração e roteiro físico](../../docs/features/mobile-authentication.md) e [decisão de sessão/nonce](../../docs/decisions/0008-mobile-auth-sessions.md).

`flutter analyze`, `flutter test`, `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:18080/` e `flutter build ios --simulator --debug --dart-define=API_BASE_URL=https://localhost/` usam Flutter 3.47.8. A origem nos builds de verificação não comprova servidor acessível nem login. Configuração real exige IDs/callback/capability aprovados; tokens/chaves privadas não entram em dart-defines. Novas features protegidas usam AuthController.authorized, sem segundo mecanismo de refresh.


PR-01.C: configuração pública por ambiente em `config/auth.public.example.json` (valores deliberadamente vazios). Copiar para arquivo `.local.json` ignorado e preencher somente dados aprovados; usar `--dart-define-from-file=config/auth.public.local.json`. Nunca incluir chaves/segredos de servidor. [Readiness e configuração nativa](../../docs/features/authentication-release-readiness.md) e [evidência separada por categoria](../../docs/architecture/pr-01c-completion-report.md). `flutter test integration_test/auth_native_test.dart -d <simulador-limpo>` verifica armazenamento e guards sem autenticar com terceiros.
