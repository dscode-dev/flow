# Integração exata do PR-01.B

Backend entregue no PR-01.A. Fonte de verdade dos schemas: `contracts/openapi/flow.yaml`. Este documento especifica comportamento do cliente; nenhuma tela, SDK OAuth Flutter ou teste físico foi implementado/executado neste ciclo.

## Regras comuns

- HTTPS e base URL do ambiente, sem hostname embutido em contrato. JSON em bodies e `Accept: application/json`. Body máximo Identity 32 KiB. Nunca enviar credencial em URL/query ou logs.
- Somente PHONE, GOOGLE e APPLE. Sem senha, reset ou exigência adicional de telefone após login social. Não pedir localização/contatos no onboarding.
- Nas rotas protegidas, `Authorization: Bearer <access_token>` Flow. ID token Google/Apple é prova de login/vínculo, não bearer da API Flow.
- Cadastro/login retornam 200 no mesmo modelo `{tokens,user}`. `user.onboarding_required` determina a tela inicial. Não inferir cadastro novo por e-mail, telefone ou erro.
- `tokens`: access_token, token_type=Bearer, expires_in (segundos restantes), refresh_token, session_id e session_expires_at (UTC). Manter refresh em SecureStore, access em memória quando possível, nunca preferências comuns ou analytics. Token de provedor só permanece em memória até enviar a prova.
- Erro: `{error:{code,message,request_id}}`. Usar code estável para fluxo, mensagem segura e request_id para suporte. 429 possui Retry-After conservador (60s); respeitar também o cooldown retornado. Aguardar janela maior quando quota horária/diária estiver esgotada; não entrar em loop de retry.
- 401 em rota protegida pode renovar uma vez por single-flight. 403 account_restricted bloqueia fluxo; não tentar outro provedor para contornar. 503 não significa usuário inexistente e não permite estado autenticado local sem sessão válida.

## Login PHONE

1. `POST /v1/auth/phone/challenges` com `{phone:"+55...",purpose:"login"}`. Usar entrada internacional iniciada em +; o servidor valida e normaliza E.164. Países permitidos começam por BR.
2. 201 retorna `{challenge_id,expires_at,resend_after_seconds}`; não há OTP/telefone na resposta. Mostrar prazo e bloquear reenvio até cooldown. Não afirmar que o SMS chegou só porque a API aceitou a solicitação.
3. `POST /v1/auth/phone/verify` com `{challenge_id,code,device:{platform:"android"|"ios",app_version:"0.1.0",label:"opcional"}}`.
4. Desafio é single-use e permite no máximo cinco verificações. invalid_credential inclui expirado/exaurido/consumido/OTP incorreto; pedir nova solicitação após cooldown conforme UX. Nunca inserir código de desenvolvimento.
5. Reenvio é novo POST challenges, mesma finalidade e telefone, após cooldown. Challenge anterior deixa de valer, mesmo se o provedor reutilizar o código. Timeout no envio/verify não autoriza repetir automaticamente: a prova pode ter sido consumida; iniciar nova tentativa quando permitido.

## Login GOOGLE

1. `POST /v1/auth/oidc/challenges` com `{provider:"GOOGLE",purpose:"login"}` → challenge_id, expires_at, resend_after_seconds=0 e nonce.
2. Solicitar credencial Google usando client ID real aprovado e **o nonce exato** retornado. Usar fluxo OIDC/nativo que suporte nonce; Android Credential Manager é uma opção documentada. Se o SDK escolhido no iOS não permitir nonce, selecionar integração OIDC compatível antes de implementar; não omitir a proteção nem enviar nonce independente sem claim assinado.
3. `POST /v1/auth/google` com `{challenge_id,id_token,device}`. Não enviar sub/e-mail separado. Código OAuth não substitui id_token neste contrato. Para um fluxo que precise de code exchange público no dispositivo, usar PKCE/state e redirect verificado; não alterar o fluxo de backend silenciosamente.
4. Descartar ID token local após o uso; tratar `user.onboarding_required`. Não solicitar telefone para completar esse login. Provedor indisponível (503) deve produzir estado de erro, sem mock de sucesso.

## Login APPLE

1. `POST /v1/auth/oidc/challenges` com `{provider:"APPLE",purpose:"login"}`.
2. Usar nonce retornado diretamente no request nativo Apple. Ele **já é SHA-256 hexadecimal**; não aplicar outro hash. Se uma biblioteca receber rawNonce e aplicar hash internamente, adaptar a chamada corretamente ou escolher API que aceite nonce final. O claim deve ser idêntico ao retorno do backend.
3. `POST /v1/auth/apple` com `{challenge_id,id_token,device}`. Este fluxo não envia authorizationCode para o backend e não exige Team ID/chave `.p8` no app. Não enviar nome/e-mail/subject do cliente para identificar conta. Nome pode vir só no primeiro consentimento e não é dependência do backend.
4. Não assumir que e-mail real/relay liga contas. Validar configuração Apple Developer/App ID/bundle e audience antes de homologação externa. Service ID só se houver fluxo aprovado que o use.
5. Observar credential-state changes nativas. revoked/notFound: limpar sessão local e solicitar logout quando possível; notificações Apple verificadas no servidor revogam sessões entre dispositivos. account-deleted Apple não comprova eliminação dos dados Flow.

## Renovação e saída

`POST /v1/auth/refresh` com `{refresh_token}`. Serializar por sessão, com exatamente uma requisição de refresh em voo. Ao receber 200, substituir o refresh no armazenamento seguro de forma atômica antes de liberar novas tentativas. Não repetir refresh antigo em timeout ambíguo: reuso com segredo correto revoga a família inteira, incluindo o par recém-emitido. Nesse caso reiniciar autenticação por provedor.

`POST /v1/auth/logout` com bearer atual → 204. Limpar armazenamento local mesmo que receba 401 (sessão já revogada). Não confundir ausência de rede com revogação comprovada no servidor; saída local deve limpar segredos e informar limitação de rede quando necessário. Não existe logout por simples device_id fornecido pelo cliente.

Sessões possuem expiração absoluta, não estendida pelo refresh. Access anterior pode coexistir até TTL, mas revogação/status sempre prevalecem no servidor. Ao receber session_limit, orientar uso de dispositivo ainda autenticado para revogar sessão ou seguir suporte conservador; não simular nova sessão.

## Perfil inicial

`GET /v1/me` retorna id/status/created_at/onboarding_required/profile. Campos profile: display_name, handle nullable e avatar_ref nullable; não há upload/edição geral de perfil.

`PATCH /v1/me/onboarding` com `{display_name,handle}`. Display name: trim/NFC, 1–80 caracteres, sem controles invisíveis. Handle: trim/lowercase ASCII, 3–30, começa com letra, restante `[a-z0-9_]`; não aceitar Unicode ou afirmar reserva local. handle_unavailable inclui reserva/colisão. Repetir o mesmo conteúdo normalizado é seguro; edição posterior diferente gera onboarding_already_completed.

## Reautenticação, vínculo e desvínculo

Criar challenge com purpose reauth/link, bearer da sessão e provedor desejado. Para PHONE incluir phone. Para OIDC iniciar request no SDK com nonce exato. Challenges ficam vinculadas à sessão e não podem ser reaproveitadas para login ou outra conta.

`POST /v1/auth/reauthenticate` com `{provider,challenge_id,credential}`; credential é OTP PHONE ou ID token social. O método precisa já pertencer à mesma conta. 204 renova janela sensível de cinco minutos; refresh não a renova.

`POST /v1/me/identities/link` usa o mesmo modelo de prova, mas challenge purpose link. Exige autenticação recente ao criar e ao consumir. Se reauthentication_required, concluir reauth por método existente, depois criar challenge link nova para método novo. identity_conflict não revela outra conta e não autoriza merge/transferência. Mesmo dono já vinculado/repetição do desafio link consumido são idempotentes e não geram efeitos duplicados.

`GET /v1/me/identities` → `{items:[{id,provider,verified_at}]}`, sem subjects/telefone/e-mail. `DELETE /v1/me/identities/{identityId}` exige autenticação recente e outro método disponível. last_identity impede remoção; o cliente deve preservar estado e orientar a vincular outro método. Ownership revogado fica reservado; não apresentar unlink como autorização para transferir a identidade a outra conta.

## Dispositivos/sessões

`GET /v1/me/sessions` → items com id/current/timestamps/device. Labels são opcionais e editáveis somente na criação deste ciclo; nenhum hardware ID ou fingerprint. Lista completa de ativas tem limite configurado até 20.

`DELETE /v1/me/sessions/{sessionId}` revoga sessão da mesma conta, idempotente enquanto a chamadora permanece válida; outra sessão exige autenticação recente. `POST /v1/me/sessions/revoke-all` exige autenticação recente e inclui a atual. Após sucesso, limpar armazenamento e voltar ao estado não autenticado.

## Gates exatos do PR-01.B

1. Implementar Welcome, escolha de método, OTP, login social, onboarding e estados usando os contratos acima, Riverpod/Dio/SecureStore existentes, sem senha ou telefone obrigatório após social.
2. Confirmar bundle/application IDs, client IDs/azp, callbacks/associações de domínio e SDKs com nonce; para Apple, evitar hash duplo. Não publicar ícones/IDs de scaffold como finais.
3. Restaurar sessão pelo refresh single-flight; implementar rotação atômica, 401/403/409/429/503 e logout/expiração sem loops. Nunca tratar token externo como bearer Flow.
4. Homologar credenciais reais e delivery SMS, login Google/Apple e notificações Apple em ambiente apropriado; separar isso dos testes locais aprovados. Nenhum teste físico foi feito em PR-01.A.
5. Revisar avisos de privacidade, política de menores, finalidade/base legal, orçamento SMS, suporte e retenção antes de onboarding real. LGPD não é presumida pela implementação técnica.
