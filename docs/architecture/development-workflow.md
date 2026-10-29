# Fluxo de desenvolvimento

## Ferramentas selecionadas

Go **1.27.3**, Flutter **3.47.8**, Dart **3.13.7** incluído no Flutter. Versões fixadas em go.mod, imagem, CI e `.fvmrc`. Pacotes diretos resolvidos com locks: chi, pgx, Redis, amqp091, goose e OTel no Go; Riverpod 3.4.3, go_router 18.1.1, Dio 5.11.1 e secure storage 11.2.0 no mobile. sqlc **1.31.1** é ferramenta de geração, não dependência de runtime.

Referências consultadas em 27/10/2026: [Go downloads](https://go.dev/dl/?mode=json), [Flutter SDK](https://docs.flutter.dev/install/archive), [tag Flutter](https://github.com/flutter/flutter/releases/tag/3.47.8), [Riverpod](https://pub.dev/packages/flutter_riverpod), [go_router](https://pub.dev/packages/go_router), [Dio](https://pub.dev/packages/dio), [secure storage](https://pub.dev/packages/flutter_secure_storage). SDK selecionado também verificado executando `flutter --version --machine`. Não atualizar SDK compartilhado automaticamente: usar instalação isolada ou FVM.

## Ciclo

1. Ler escopo, ADRs, contratos e limitações da auditoria. Examinar Git e não apagar alterações de outro autor.
2. Definir contrato da feature, regras de acesso, dados necessários e retenção antes do endpoint. Atualizar `docs/admin-capabilities.md` em toda mudança administrativamente relevante.
3. Implementar dentro do módulo dono. Mudança de schema usa goose; consultas usam sqlc e `make sqlc` gera código tipado. Nunca editar dbgen manualmente.
4. Executar apenas checks pertinentes e registrar resultados reais. `make backend-check`, `make mobile-check`, `make contracts` e `make smoke` cobrem a fundação. Smoke interrompe somente Redis desta stack por instantes, depois restaura.
5. Revisar exposição de dados, compatibilidade e migrações. Commit/push só com autorização explícita. CI de PR não publica nem implanta serviços.

## Mobile e deep links

Configuração via `--dart-define=FLOW_ENV=development --dart-define=API_BASE_URL=https://SEU_HOST/`. A URL precisa terminar em `/`; inclui prefixo quando aplicável. Não há host padrão. Runtime não contém segredo injetado por dart-define: valores compilados são públicos. Nunca colocar credenciais privadas nele.

go_router usa Router API e resolve caminhos em um só lugar. Rotas ainda não implementadas exibem erro recuperável. PR-01.B implementará guard reativo para `unknown`, restauração, expiração e retorno após login, com destino interno validado; nenhum redirecionamento externo arbitrário. Não transportar bearer em links. Universal Links/App Links exigem domínio real verificado, association files, IDs de app e certificados; sem domínio disponível, não inventar manifests de produção. A infraestrutura Dart de links está pronta; associação nativa verificada permanece um gate manual do PR-01. Não criar rotas fictícias de experiências ou Radar para simular essa integração.

Os projetos Android/iOS são scaffolds novos, com IDs `com.example` e ícones Flutter padrão **não aprovados como marca**. Não publicar esses identificadores/ícones. A equipe de assinatura local foi removida. Substituir IDs, signing e assets somente pelos valores verificados do produto. Android desabilita backup para dados sensíveis; iOS usa entitlements de Keychain sem grupo de outros apps. Flow segue como implementação nova conforme ADR 0005, sem migração de armazenamento legado.

## Validação manual antes de release

- Android e iOS físicos: instalar build assinado, abrir/retomar, trocar claro/escuro, ampliar fontes, TalkBack/VoiceOver, testar teclado e sheets.
- Validar URL HTTPS alcançável pelo dispositivo, perda/retorno de rede, deadlines e mensagens sanitizadas. `localhost` de um telefone aponta para o próprio telefone, não para o host Docker.
- SecureStore: escrever valor de teste sem credencial real, reler após reinício, apagar, verificar bloqueio/desbloqueio e ausência em backup/logs. Nenhum teste de widget comprova Keychain/Keystore.
- App Links/Universal Links: domínio e assinatura reais, app fechado/aberto, links inválidos, host indevido, usuário sem sessão, sem loop ou acesso antecipado.
- Em PR-01.B e homologação de release, validar telas novas, navegação e SDKs nativos; nenhum teste físico é exigido ou executado em PR-01.A.
- P2P: usar plano dedicado no ADR 0003, não marcar por teste em simulador.

## CI

GitHub Actions executa Go format/vet/test, OpenAPI, geração sqlc sem divergência, Flutter format/analyze/test e smoke Compose com rollback/up e falha de Redis. Não há publicação, push de imagem, conta de fornecedor, credenciais de produção ou suite de negócio inexistente. Segredos de teste são gerados durante o job; teardown preserva volumes por padrão.

Identity: `make identity-test` executa HTTP real com PostgreSQL isolado e Redis parado; `docs/features/identity.md` descreve arquitetura/provedores e `identity-mobile-integration.md` define os contratos PR-01.B. Não rodar novamente suites Flutter sem alterações mobile.
