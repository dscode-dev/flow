# ADR 0008 — Autenticação Flutter e continuidade segura da sessão

Status: implementado no PR-01.B; homologação externa pendente. 29/10/2026.

## Autoridade e fronteiras

AuthController é a única autoridade local, injetada por Riverpod. ValueNotifier fornece snapshots imutáveis para telas e refreshListenable do go_router. A API Go continua autoridade de identidade, status, onboarding, quota, expiração e revogação. Telas não navegam após login/onboarding: o router observa o estado. Interceptors não navegam.

IdentityApi contém operações tipadas e Dio sem retry automático. Bearer Flow só é enviado em rotas protegidas. Novas features devem usar AuthController.authorized para toda chamada protegida; nunca adicionar um segundo mecanismo de refresh nem obter o Dio cru para contornar esse coordenador. GET pode repetir uma única vez após renovação. Escritas não são repetidas automaticamente. Cancelamento de requests ocorre ao sair/descartar o coordenador; respostas atrasadas são invalidadas por geração.

## Prova Google

A API 7.2.0 do singleton inicializa uma única vez e recebe nonce somente em initialize; authenticate não permite substituir nonce. Cada challenge Go exige nonce novo. Escolhemos as implementações federadas oficiais GoogleSignInAndroid 7.2.18 e GoogleSignInIOS 6.3.8, instanciadas e inicializadas uma vez por tentativa serializada. Elas repassam nonce ao Credential Manager/SDK Google iOS. Não reinicializamos GoogleSignIn.instance e não usamos lightweight authentication para estabelecer sessão Flow. Um preflight verifica IDs e, no iOS, a presença do callback correspondente no Info.plist antes de abrir o SDK. O cache nativo é limpo antes/depois; só idToken vai ao backend, nunca e-mail/sub/avatar/access token Google. O adapter está confinado e seu contrato é testado. Esta escolha aumenta acoplamento às APIs federadas; revisar a cada atualização.

Fontes: [migração 7](https://github.com/flutter/packages/blob/main/packages/google_sign_in/google_sign_in/MIGRATION.md), [API authenticate](https://pub.dev/documentation/google_sign_in/latest/google_sign_in/GoogleSignIn/authenticate.html), [integração Android](https://pub.dev/packages/google_sign_in_android), [integração iOS](https://pub.dev/packages/google_sign_in_ios). Versões efetivamente resolvidas no pubspec.lock.

## Apple

Plugin mantido sign_in_with_apple 8.2.0, apenas nativo iOS neste ciclo. Nonce final retornado pelo Go é usado sem novo hash. State aleatório de 256 bits é conferido; não pedimos scopes de nome/e-mail e ignoramos authorizationCode. O identificador nativo Apple é metadado restrito criptografado apenas para consultar CredentialState ao restaurar/retomar. revoked/notFound encerra Flow com logout quando possível. Falha da consulta não é prova de revogação; backend segue validando sessão e notificações Apple. Não há polling constante nem fluxo web Android sem Service ID/callback aprovado.

## Armazenamento, crash e concorrência

Uma chave SecureStore contém JSON versionado: refresh, session_id, expiração absoluta e, somente para Apple, identificador nativo. Access e perfil ficam em memória. Escritas/limpeza formam fila; resultados de geração anterior não podem substituir uma sessão nova. Login só libera navegação depois da persistência.

Refresh é single-flight. Antes da chamada, sobrescrevemos o registro com `{v:1,pending:true}` sem segredo antigo. Depois de resposta válida, gravamos o par novo (somente refresh persistido), então liberamos requests. Crash/timeout/resposta inválida/falha ao persistir exigem nova autenticação. Um restart com journal pendente nunca reutiliza o refresh antigo. Não existe grace, retry ou fallback. Preferimos perda local de continuidade a revogar a família por replay. Atualização de uma chave é unidade de substituição do Keychain/armazenamento criptografado Android, não transação multi-key.

401 atrasado de access anterior usa a renovação já concluída. Segundo 401, expiração absoluta e account_restricted limpam a sessão e fecham a navegação. Logout limpa local mesmo sem rede; UI distingue isso de revogação remota confirmada. Falha do SecureStore bloqueia login até limpeza explícita bem-sucedida. Cancelamento não comprova ausência de efeito no servidor.

## Navegação e retomada

Bootstrap sem perfil confirmado fica no gate. Revalidação/refresh com perfil já conhecido mantém formulário/shell, preservando dados em memória; envio de formulário e chamadas protegidas aguardam persistência. Refresh de restauração não tem perfil e continua no gate. Só `/app` é destino protegido aprovado neste ciclo, sem query/fragment/returnTo externo. Novas rotas exigirão ampliar explicitamente a allowlist; não há domínios de universal/app links fictícios. Onboarding usa apenas display_name/handle e a resposta Go; conflito mantém formulário, confirmação libera shell identificado como desenvolvimento.

Vínculo/reauth não usam o fluxo de login: serão coordenadores separados em configurações, com bearer, purpose link/reauth, prova nova, recent-auth e erros de ownership. Este PR não cria UI nem inferência de merge por e-mail/telefone.
