# Relatório de execução — PR-02.B

07/11/2026, America/Recife. Implementação Flutter Experiences disponível no workspace. Sem staging, commit, push, merge ou deploy. Homologação física e infraestrutura produtiva não são presumidas pelos testes locais.

## 1. Git inicial

Branch `main`, HEAD `92a6ada32c0bfd6a7b66590447034accd1d91a84`, com dez arquivos modificados e oito não rastreados de trabalhos anteriores. SDK persistente, Personal Team e configuração LAN foram preservados. Relação exata e inspeção obrigatória em [revisão inicial](pr-02b-initial-review.md). Configurações/segredos locais continuam ignorados.

## 2. Arquivos e arquitetura

| Grupo | Entrega |
| --- | --- |
| `apps/mobile/lib/features/experiences/domain/` | Experience/Input/página/categoria tipados, enums, IANA/DST, erros seguros e fronteira de busca |
| `features/experiences/data/` | Repository com Dio/Identity existentes, upload S3 isolado, validação/orientação/metadados da capa |
| `features/experiences/application/` | Coordenadores de lista/detalhes/editor, cancelamento, idempotência, escopo de conta e conflitos |
| `features/experiences/presentation/` | Três páginas e componentes de resumo/status/capa |
| Mobile existente | Router protegido, pubspec/lockfile, descrição de galeria no Info.plist e adaptação do teste de onboarding ao novo destino |
| Testes | Sete arquivos Flutter novos, incluindo suporte de fixtures; bridge Go apenas de integração |
| Operação | Target/script/CI do smoke; overlay/helper LAN agora configuram também o S3 privado alcançável |
| Documentação | Revisão inicial, [guia Flutter](../features/flutter-experiences.md), este relatório, READMEs, privacidade e ADM-025 |

Versões resolvidas: Flutter3.47.8/Dart3.13.7, timezone0.11.2, image_picker1.2.4, image4.12.0, uuid4.6.0. Nenhum framework de backend/estado ou refresh paralelo foi introduzido. Domínio, endpoints, SQL/migrations e OpenAPI produtivos não precisaram de alteração.

Inventário dos novos arquivos mobile: `domain/experience.dart`, `experience_time.dart`, `experience_issue.dart`, `location_search.dart`; `data/experiences_repository.dart`, `cover_upload.dart`; `application/experience_controllers.dart`; `presentation/pages/my_experiences_page.dart`, `experience_editor_page.dart`, `experience_detail_page.dart`; `presentation/widgets/experience_widgets.dart`, todos sob `features/experiences`. Testes novos: `experience_domain_test.dart`, `experience_controllers_test.dart`, `experience_widgets_test.dart`, `experiences_api_test.dart`, `experiences_contract_test.dart`, `cover_selection_test.dart` e `support/experience_fakes.dart`. Harness novo: `backend/internal/experiences/integration/flutter_contract_test.go`. Os três documentos novos são os relatórios inicial/final e o guia Flutter vinculados acima.

## 3. Páginas e navegação

Minhas experiências em `/app` e `/experiences`, criação em `/experiences/new`, edição em `/experiences/{UUID}/edit`, detalhes em `/experiences/{UUID}`. Formulário progressivo com revisão, salvamento explícito, aviso de alterações não salvas e validação contextual. Lista com filtro/cursor, vazio, carregamento, falha/retry, estado/categoria/agenda/capa e ações contextuais. Detalhes com redaction, organizador disponível na API, ticket externo e gestão autorizada.

Rotas exigem sessão/onboarding PR-01, só retêm destinos internos reconhecidos e não usam returnTo externo. Deep links internos por UUID entregues; associação nativa de domínio permanece externa. `ExperienceSummary`, `ExperienceStatusBadge` e `ExperienceCover` são reutilizáveis por módulos futuros, sem ampliar audiência/discovery.

## 4. Integração real

`make experiences-mobile-contract` passou com Flutter/Dio/AuthController → Go HTTP/OpenAPI → PostgreSQL/PostGIS e S3 SeaweedFS reais. Destinos exclusivos `flow_experiences_test` e `flow-experiences-test`; dados/bucket de aplicação não foram usados como fixtures. O harness cria sessões sintéticas somente no binário de teste e valida respostas contra OpenAPI. Não existe endpoint de fixture no produto, mock de produção ou novo mecanismo de login.

Observados: catálogo real, criação/replay idempotente, lista própria, GET/PUT, publicação inválida422 e válida, edição permitida de publicação, conflito412, acesso PUBLIC/UNLISTED, negação PRIVATE/draft, histórico redigido, capa autorizada, cancelamento/arquivo, transição inválida e sessão revogada. Fixture de sessão não comprova OAuth/Apple/Twilio reais.

## 5. Capa e armazenamento

Galeria → limites de bytes/dimensões antes de decodificar → normalização EXIF/metadados em isolate → autorização idempotente → multipart S3 real com fields intactos/file por último, sem bearer/cookies → confirmação READY do mesmo ID → associação pelo documento completo → leitura autorizada. Bytes finais determinam tamanho/MIME assinados. Picker reduz dimensões para manter o orçamento de pixels; PNG processa somente o primeiro frame.

Retry de confirmação não reenvia binário; autorização expirada exige nova intenção explícita. READY não é anunciado como associado antes de salvar. Capa usa pixels próprios, sem cache global/disco ou signed GET. Expiração do PR-02.A afeta POST, não leitura. Perda de acesso na capa força revalidação dos detalhes sem loop para a mesma versão; redaction/404 remove conteúdo antigo. Sem vídeo/P2P ou URL arbitrária.

O overlay local expõe só API e S3 privado no IPv4 privado detectado, mantendo banco/Redis/RabbitMQ em loopback e volumes preservados. Readiness200; acesso S3 sem autorização negado403. Produção exige HTTPS e provisionamento privado aprovado; o cliente produtivo recusa autorização S3 HTTP.

## 6. Agenda e local

Fuso IANA escolhido explicitamente; instantes UTC preservados na edição. Conversão civil por offsets da base e round-trip, sem offsets fixos do aparelho. Gap DST recusado e overlap exige escolha. Testes: Nova York, meia hora de Lord Howe, dia suprimido de Apia e meia-noite de Recife. Venue/endereço/ponto manual permitem outra cidade, sem GPS/background/histórico. Mapbox não configurado: fronteira verificada/desativada, sem mapa ou busca falsos.

## 7. Lifecycle, concorrência e segurança

Go autoriza todos os comandos; UI só sugere ações por autoria/estado/fase, pois o contrato não fornece can_edit/permissions. PUT completo conserva campos protegidos de publicação e ETag forte. 412 mantém edição e oferece comparação/recarga confirmada, sem retry com nova versão. Criação congela chave/corpo durante ambiguidade, mantém ID já recebido e não renova silenciosamente a janela24h. Single-flight bloqueia duplicação por toques.

Só GET pode repetir pelo coordenador central após refresh. Retry-After é respeitado antes de outra chamada de rede. Saída/restrição/mudança de conta cancelam requests e limpam dados, pixels e campos visuais. Resultados tardios de picker/data/local de outra sessão são ignorados. Revalidação por GET na retomada/atualização; não há push realtime de moderação neste contrato. Ticket externo exige aviso/HTTPS e não confirma pagamento.

## 8. Validações executadas

| Verificação | Evidência |
| --- | --- |
| Flutter analyze | Sem issues após revisão final |
| Suíte Flutter geral | 69 aprovados; dois skips explícitos de contratos que exigem harness |
| Testes adicionais de capa | Dois aprovados: orientação/metadados e limites/tipos/dimensões |
| Regressões finais afetadas | 15 aprovados, incluindo duas novas regressões de privacidade: total de73 casos unit/widget distintos cobertos nas execuções |
| Smoke Flutter/Go/PostGIS/S3 | Um caso integrado aprovado; Go17,408s, Flutter um teste; inclui validação OpenAPI |
| Python | 14 aprovados: preflight mobile, LAN segura e readiness anterior preservado |
| Android debug | APK gerado; primeira compilação137,4s, incremental final26,3s antes do fechamento |
| iOS simulador | App gerado; primeira compilação147,2s; incremental final31,0s aprovado |
| Higiene | git diff --check, shell do harness e plist iOS válidos; pub get --enforce-lockfile aprovado; formatação42 arquivos/zero mudanças |

As falhas iniciais de layout com texto ampliado, notificações durante build, bindings de teste que bloqueavam HTTP e imports do harness foram corrigidas; somente resultados aprovados acima constituem evidência. Não foram repetidas suítes Go não afetadas, rollback de dados de aplicação ou smoke destrutivo do banco principal.

## 9. Pendências externas e validação física

Configuração/homologação Google/Apple/Twilio, IDs definitivos, marca, URLs legais e origem HTTPS permanecem pendentes. Sem essas credenciais não existe login real de sucesso no app. Mapbox/geocoding/mapa exigem configuração aprovada própria. API/S3 produtivos exigem TLS, IAM/bucket privado, região/fornecedor, lifecycle/backups e manutenção/alertas operacionais.

O proprietário ainda deve testar Android/iPhone com sessão real: selecionar JPEG/PNG/HEIC conforme conversão do OS, orientação/cores, recusa de permissão, interrupção e morte da Activity, rede S3/expiração, teclado/acessibilidade nativos, lifecycle e retorno de links. Builds não comprovam esses fluxos. Não foi reinstalado/aberto o PR-02.B em aparelho autenticado nesta execução.

## 10. Privacidade e administração

[Inventário mobile](../privacy/data-governance.md) registra formulário/intenção em memória, cache temporário do picker/OS, bytes/pixels, descarte, destinatário S3 e saída para ticket. Sem localização do usuário, analytics novo, câmera/vídeo ou cópia persistente própria de capa. Responsáveis/avisos/base/menores e fornecedores ainda exigem validação.

[ADM-025](../admin-capabilities.md) cobre criação/publicação, categoria, conflitos, visibilidade, mídia por etapa, links e limpeza/alertas, com diagnóstico categórico/request_id. Sem plataforma, endpoint ou role administrativa.

## 11. Limites

Formulário e chave pendente só persistem na memória da edição; encerramento do processo perde alterações não salvas. Antes de repetir criação ambígua após reinício, conferir a lista. Sem banco offline/autosave implícito. Categoria histórica é preservada, mas nova publicação depende do catálogo habilitado. Cursores expiram15min: recarregar lista reinicia paginação. Reencodificação não é moderação/antivírus; ticket não é comprovante. UI não conhece mudanças remotas até revalidação/resposta, sem contrato realtime atual.

## 12. Status PR-02.B

**PR-02.B concluído no escopo técnico local**, com builds incrementais Android debug e iOS simulador aprovados após a revisão final. Não há aceite de produção ou homologação física implícitos. Pendências externas e critérios PR-03 são os registrados abaixo/acima; nenhum commit/push/deploy foi realizado.

## 13. Critérios exatos para PR-03

1. Consumir ID, lifecycle, audiência, API1.1.0 e rotas/componentes documentados; não ampliar PRIVATE/UNLISTED nem inferir autorização por UUID/ticket.
2. Manter Identity/Dio/refresh centrais, revalidação/no-store e descarte por conta; escritas condicionadas/idempotentes conforme operação.
3. Preservar como gates Flutter analyze/testes, builds Android/iOS e smoke real Experiences; CI está configurada, mas não foi executada remotamente sem push.
4. Se PR-03 exigir teste físico com pessoas, primeiro configurar/homologar Identity e endpoints alcançáveis HTTPS; se exigir mapa/busca, aprovar/configurar Mapbox e seu inventário antes de declarar integração concluída.
5. Tratar RSVP/Participation/Event Space/feeds/Flows/pagamento como contratos de seus próprios ciclos. Não considerar estas capacidades entregues por PR-02.B.
