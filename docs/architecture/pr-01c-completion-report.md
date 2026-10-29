# Relatório de execução — PR-01.C

29/10/2026. **Implementação concluída / homologação externa pendente.** Não há aceite integral do ciclo de identidade nem autorização de distribuição. O proprietário confirmou que IDs finais, configurações de terceiros, origem HTTPS, marca e URLs legais ainda serão criados. Nenhum commit, push, merge ou deploy realizado.

## Estado inicial e escopo

Branch main, origin/main, HEAD `7b6225629234ef9e38b1bf95a321b6ff0b2b97ce` (implementa PR-01.B), workspace limpo. [Revisão inicial](pr-01c-initial-review.md). Inspecionados relatórios A/B, OpenAPI, contratos e fontes Flutter/Go, Android/iOS, Compose, env e CI. Não houve alteração de contratos, migrations ou código de produção Go; novo arquivo Go existe exclusivamente no pacote/binário de testes de integração.

## Trabalho concluído e achados

| Achado | Classificação e correção | Evidência atual |
| --- | --- | --- |
| Refresh notificava listeners antes de instalar single-flight, permitindo reentrada e dois usos do mesmo refresh | Alta; corrigido: instalar future antes de executar/notificar | Regressão falhou antes com 2 requests, passou depois com 1; contrato real Go/PG preserva sessão após concorrência |
| Logout considerava qualquer 401 como revogação, inclusive access expirado | Alta; corrigido: só 204 confirma operação; quando seguro, remover segredo do disco, renovar uma vez e revogar com access novo. Sem repetir refresh em voo/ambíguo | Regressões falharam antes; Flutter/Go/PG expira access, observa 401, rotação e revogação efetiva do access novo |
| Resultados/mutações anteriores podiam afetar estado de sessão posterior | Média; geração reconferida após consulta Apple; onboarding vinculado à geração; logout single-flight impede nova entrada durante saída | Regressões de revalidação, onboarding atrasado, logout concorrente e resposta antiga passaram |
| Sessão emitida mas descartada por falha de persistência/saída precisava de cleanup remoto | Média; tentativa de revogar o access recebido, sem retry ou publicação local | Falha de storage controlada; API real passa a rejeitar a sessão recém-emitida |
| Revogação Apple em foreground não tinha observer nativo | Média; NotificationCenter → sinal sem PII → CredentialState no coordenador, somente para sessão Apple | Compilação/registro no iOS e regressão do coordenador passaram; revogação Apple real ainda pendente |

Revisão sem novo achado local em nonce/state, assinatura/issuer/aud/azp, não merge por e-mail, ownership de vínculo, suspensão, quotas OTP, redaction e retenção. Essas proteções têm testes locais/fixtures e PostgreSQL real; isso não substitui configuração e observação externas. Riscos SMS (incluindo posse/reciclagem/SIM swap), política de recuperação, orçamento, ingress e aprovações de privacidade ficam classificados como gates do proprietário antes de uso real, sem aceitação automática de risco.

## Entregas

- AuthController: concorrência, logout/401/refresh seguro, descarte de sessão e publicação por geração; regressões focadas. AppDelegate/FlowApp: observer nativo Apple sem payload pessoal.
- Template `apps/mobile/config/auth.public.example.json` vazio; arquivo local ignorado; `scripts/auth-readiness.py`/`make auth-readiness` validam estrutura e imprimem apenas categorias, nunca valores. Whitelist impede segredo no JSON público.
- Bridge `_test.go` com build tag integration e teste Flutter `identity_contract_test.dart`: API Go/OpenAPI/PostgreSQL reais, fornecedores exclusivamente de fixture. Rotas `__fixture` não existem no binário de produção. Target `make identity-mobile-contract` e CI preparados para essa validação.
- Smoke nativo `integration_test/auth_native_test.dart` com integration_test do SDK; usa armazenamento real de OS, sem mock de autenticação nem conta real.
- [Configuração nativa/ambientes, owners e homologação](../features/authentication-release-readiness.md). Integração mobile, ADR 0008, READMEs, governança e ADM-013 atualizados. Sem redesign, novas páginas de produto ou ativos de marca inventados.

## Evidências por categoria

| Categoria exigida | Resultado observado nesta execução | Limite |
| --- | --- | --- |
| 1. Automatizados locais — Flutter | `make mobile-check FLUTTER=/private/tmp/flow-flutter-3.47.8/bin/flutter`: lockfile, análise sem issues, **48 testes aprovados e 1 skip explícito** | Skip é o contrato que exige bridge; executado separadamente abaixo |
| 1. Automatizados locais — Go/PostgreSQL | `make identity-test`: 9 grupos principais e 10 subcenários passaram; PostgreSQL real em flow_identity_test e Redis realmente indisponível/restaurado | Upstreams OAuth/Twilio controlados, não fornecedores reais |
| 1. Contrato Flutter ↔ Go/PG | `make identity-mobile-contract FLUTTER=/private/tmp/flow-flutter-3.47.8/bin/flutter`: passou; última execução Go **23,996s**, cliente Flutter **1 teste aprovado** | Cadastro Google/Apple, retorno Google, PHONE request/resend 429/prova, onboarding, restore, rotação concorrente/replay, logout, persistência falha e suspensão; proofs de fixture |
| 1. Auditor e análise focada | **4 testes Python** passaram; go vet com tag integration, formatação e diff checks passaram | Auditor é estrutural e não verifica console/rede/conteúdo jurídico |
| 2. Simulador executado | iPhone 16 virtual Flow-PR01C, **iOS 26.3**, smoke nativo **1 teste aprovado**; Keychain write/read/delete, journal interrompido, guard `/app`, preflight Google ausente, eventos lifecycle injetados no Flutter | Não é iPhone físico nem login OAuth; evento Apple real não foi disparado |
| 2. Compilações | APK debug e app iOS normal para simulador passaram; assinatura debug APK verificada com apksigner | Não é release assinado/distribuído; Android emulador não foi executado |
| 3. Aparelhos físicos | iPhone foi detectado; nenhuma instalação/teste físico realizado | IDs/equipe/provisionamento/provedores aprovados ainda inexistentes. Android físico não foi exercitado |
| 4. Terceiros reais | **Não executado:** SMS, consentimento/login Google/Apple e notificações Apple reais | Credenciais/configuração ainda não existem, conforme confirmação do proprietário |
| 5. CI | Run [40956755713](https://github.com/dscode-dev/flow/actions/runs/40956755713), commit inicial `7b62256…`, backend/mobile/infrastructure **success**, consultado no GitHub | Verde pertence ao HEAD anterior. Novos passos/código locais precisam de CI após commit/push autorizado; nenhuma execução remota foi disparada |
| 6. Produção | Auditor retornou **exit 1 com 12 pendências estruturais**; apenas formato da HMAC local passou | Não comprova HMAC de produção, publicação, segurança operacional ou aceite final |

Builds usam Flutter 3.47.8 / Dart 3.13.7 isolados; SDK global preservado. No contrato Go, migrations/truncates atingiram somente flow_identity_test, nunca o banco principal. Testes não enviaram SMS nem chamaram verificadores reais externos. Perda de rede foi controlada nos testes locais; modo avião, troca real de apps e interrupções em aparelhos físicos continuam pendentes. Sem logs de tokens/OTP/telefone/e-mail/Authorization.

### Artefatos e assinatura observados

- APK: `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`, SHA-256 `76f79f3904d5e77b30a9d60058814c7d6211cf1ba080e3ebcbbaf6bdfdc34fad`.
- Certificado **Android Debug local**, SHA-1 `FC:0A:6F:D1:82:BE:FC:8F:23:A4:AD:AA:45:5A:11:AC:3E:2D:9F:8F`; SHA-256 `DF:80:DF:D5:44:EF:9E:73:48:F2:55:86:01:17:A5:F3:19:62:82:74:C4:FB:1A:40:44:FD:82:36:DF:DF:39:BD`. Não é chave release/Play; não registrar como se fosse. Nenhuma chave privada foi extraída/versionada.
- iOS normal: `apps/mobile/build/ios/iphonesimulator/Runner.app`; Runner SHA-256 `bdb877a9803d8ff862e60da08ddaf181b7b9ce05371d2a1ef4e975c2a6464450`; kernel Dart SHA-256 `bc6620533de68021ac1b283166557acc26f45188e5d4da37b70bdf6c8f85a02f`. Somente simulador, sem prova de assinatura/distribuição física.

## Bloqueadores, proprietários e aceite esperado

| Bloqueador | Proprietário | Ação e verificação esperadas | Evidência atual |
| --- | --- | --- | --- |
| IDs finais Android/iOS | Produto + Mobile | Aprovar applicationId/bundle, alinhar Gradle/Kotlin/manifest e build configurations iOS; conferir no artefato instalado | com.example.flow_mobile / com.example.flowMobile permanecem scaffold; proprietário confirmou ausência de IDs aprovados |
| Assinatura Android de distribuição | Mobile + responsável pela loja | Criar/guardar keystore e senhas, configurar release/Play conforme estratégia escolhida, conferir certificado efetivo | Apenas debug local verificado; release sem signingConfig |
| Equipe/capability/provisioning iOS | Apple Developer + Mobile | Configurar App ID/equipe, Sign in with Apple e profile; assinar/instalar no iPhone | Entitlement declarado, equipe/provisionamento aprovados ausentes |
| Google | Google Cloud + Mobile + Backend | Criar clientes/consentimento, package/SHA-1/bundle, server/iOS IDs, reversed callback e audiences/azp; sucesso/cancelamento reais nas duas plataformas | IDs/env/backend allowlists vazios, Auth.local.xcconfig ausente; somente fixtures/preflight local |
| Apple nativo e notificações | Apple Developer + Backend | Configurar audience/capability e endpoint HTTPS do App ID primário; validar login, retorno sem nome, revogação foreground/resume e JWS servidor | Sem configuração externa; código e observer compilados/testados localmente. Não exige .p8 neste fluxo ID-token |
| Twilio Verify | Responsável Twilio + Backend/Operação | Criar Account/Verify Service, conta/destinatário autorizado, Geo Permissions/Fraud Guard, budgets/alertas e credenciais de servidor; observar recebimento/verificação reais | TWILIO_* ausentes; nenhuma entrega real observada |
| HTTPS/ingress | Infra + Segurança | Aprovar origem/DNS/TLS, publicar API/Apple callback, definir proxy confiável/limites edge sem confiar X-Forwarded-For arbitrário | Sem origem pública/deploy. Go usa RemoteAddr; proxy pode agrupar quotas de vários usuários |
| Secret injection por ambiente | Infra + Segurança | Selecionar secret manager, persistir HMAC e credenciais independentes, validar reinício/rotação/acesso mínimo | Somente .env de desenvolvimento ignorado com HMAC local; produção não provisionada |
| Marca | Produto + Design | Fornecer logo/ícones/fontes aprovados e aprovação/versionamento; integrar e conferir nas duas plataformas | Nenhum material aprovado localizado/fornecido; texto Flow e launcher scaffold preservados |
| Termos e Privacidade | Produto + Privacidade | Fornecer conteúdo/destinos finais aprovados, verificar HTTPS/status/redirecionamentos no aparelho; aprovar LEGAL_LINKS_APPROVED | URLs ausentes; nenhum destino visitado nem texto final inventado/publicado |
| Privacidade e operação | Privacidade + Segurança + Operação | Aprovar finalidade/base legal/menores/destinatários/retenção/recuperação, agendar manutenção e validar alertas/orçamento/procedimento de suspensão | Inventário/controles técnicos existem; aceite/processos de produção não comprovados. Sem declaração LGPD |
| Homologação física/externa | Mobile + owners Google/Apple/Twilio | Executar matriz de cenários com build/contas/ambiente reais e registrar resultados separados | Simulador e fixtures aprovados; zero testes físicos/provedores reais observados |
| CI do PR-01.C | Proprietário do repositório | Após autorizar commit/push, executar workflow do novo SHA e revisar backend/mobile/infra+contrato Flutter/Go | HEAD inicial verde; workspace novo não publicado nem executado remotamente |

Apple Android web exige decisão e configuração próprias e continua fora do fluxo nativo selecionado, sem callback/Service ID fictício. UI administrativa, conta/settings e páginas futuras não foram antecipadas.

## Instruções do proprietário e fechamento

[Checklist e comandos completos](../features/authentication-release-readiness.md#homologação-do-proprietário-e-evidência-reproduzível) e [roteiro físico mobile](../features/mobile-authentication.md#execução-e-homologação-física-não-executadas). Criar os recursos aprovados, preencher somente configuração pública no app e segredos no servidor, executar auditor, compilar/assinar, escolher explicitamente Android/iPhone físicos e observar os cenários. Não reutilizar fixture ou resultado de simulador como homologação real. Registrar commit/hash, ambiente, OS, responsável, horário, resultado e request_id sanitizado; jamais tokens/OTP/PII.

Simulador isolado pode ser reutilizado em nova verificação, sempre sem sessão real. Recursos locais são encerrados preservando volumes; nenhuma chave/credencial foi publicada. Arquivos seguem no workspace para revisão, sem staging/commit/push/merge/deploy.

**Status PR-01.C: implementação concluída / homologação externa pendente.** O ciclo só pode receber aceite integral depois dos bloqueadores acima e das evidências físicas/externas/produção exigidas.
