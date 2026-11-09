# Participação, convites, agenda e check-in — PR-06

[ADR0011](../decisions/0011-participation-capacity-checkin.md) define máquina de estados, acesso privado e consistência. Implementação no módulo Go `internal/participation`, mesmo processo da API/banco; Experience continua autoridade de agenda, capacidade, audiência e lifecycle. Migrations00007/00008, repositórios sqlc, auditoria/outbox existentes. Sem novo serviço, Redis como disponibilidade, push, Event Space, Social, Chat ou venda de ingresso.

## Operações HTTP

Todas autenticadas, `/v1`, resposta no-store e erro padrão `{error:{code,message,request_id}}`. Escritas exigem onboarding/sessão/conta atuais. POST/PUT/DELETE de intenção exigem `Idempotency-Key` UUID e JSON, mesmo quando corpo é `{}`. Exceções: PUT de configuração usa If-Match composto; emissão de credencial gira o código a cada chamada e não usa recibo. Não repetir escritas automaticamente após timeout.

| Operação | Regra |
| --- | --- |
| GET `/experiences/{id}/participation` | Situação própria, interesse, modalidade, contagem/capacidade/remaining, convite próprio, presença, ações autorizadas, as_of/valid_until/checkin_open |
| GET/PUT `/experiences/{id}/participation-settings` | Somente criador; modalidade/capacidade e ETag `"configVersion-experienceVersion"`; can_manage/can_configure/visibility autoritativos |
| PUT/DELETE `/experiences/{id}/interest` | Interesse independente; sem vaga; criador não marca para si |
| POST `/experiences/{id}/participation/{confirm,request,cancel}` | Rotas explícitas, sem ação arbitrária no corpo; FREE/APPROVAL e cancelamento idempotente; PRIVATE exige convite |
| GET `/experiences/{id}/participants` | Somente criador; filtro state, nome/handle públicos mínimos, estado/bloqueio/presença; sem telefone/federação |
| POST `/experiences/{id}/participants/{userId}/{approve,decline,remove,block,unblock}` | Organizador; aprovação só PENDING e última vaga garantida no banco; recusa/remoção/bloqueio revogam convites anteriores |
| GET/POST `/experiences/{id}/invitations` | Organizador lista/convida por user_id OU handle exato; expiração opcional em horas, sem reserva de vaga |
| POST `/invitations/{id}/{accept,decline,revoke}` | Destinatário aceita/recusa; criador revoga PENDING; lotação mantém pendência |
| GET `/me/agenda` | section=upcoming/interests/pending/invitations/history; UTC/início/id, fuso IANA mantido |
| POST `/experiences/{id}/check-in-credential` | Participante CONFIRMED na janela; código efêmero, nova emissão invalida anterior |
| POST `/experiences/{id}/check-ins/validate` | Organizador confere pessoa/código; confirmação de presença separada |
| POST `/experiences/{id}/check-ins/{userId}/revoke` | Organizador revoga presença/credencial; mantém auditoria |

Contrato completo: [OpenAPI1.5.0](../../contracts/openapi/flow.yaml). Coleções limitadas a20 por padrão/50 máximo, cursor HMAC vinculado à conta/recurso/seção/filtros/limite por15min; alterações podem mudar a ordem entre consultas, então atualizar após ação/resume e deduplicar IDs. Configuração stale retorna412; lotação/capacidade/estado/replay409, código inválido422, acesso negado404 uniforme, limite429/Retry-After60. Em PRIVATE, convite expirado/revogado pode resultar404 porque não concede mais acesso ao objeto. Não contornar isso pela listagem de agenda.

## Minha Agenda

Próximas: CONFIRMED elegível/não encerrada. Interesses: marca independente elegível. Solicitações: PENDING. Convites: PENDING válido, experiência vigente. Histórico: cancelamentos, recusas, remoções, convites terminais/expirados e experiências encerradas/canceladas/arquivadas/indisponíveis. Uma experiência pode aparecer em interesse e confirmação, pois são intenções distintas. Criador usa Minhas experiências para suas próprias organizações; não é inserido como participante fictício.

Agenda consulta o agregado atual, sem copiar horário/local: alterações/cancelamentos refletem na consulta seguinte. Após perder acesso privado, somente referência pessoal redigida (ID, estado e “Experiência indisponível”), sem título/local/horário protegidos. Ordenação dessa referência usa data da relação, não horário privado. Histórico não expõe lista de outras pessoas. Nenhuma integração Google/Apple Calendar.

## Flutter e navegação

Home → Minha Agenda (`/agenda`); detalhes existentes recebem “Sua participação”, somente ações retornadas pelo backend. Gerenciar participantes (`/experiences/:id/participants`) é contextual ao criador: modalidade/capacidade, filtros de solicitações/confirmados/removidos, aprovação/recusa/remoção/bloqueio e convite. Formulário de Experience não foi reconstruído. `/experiences/:id/check-in` mostra código próprio ou conferência do organizador conforme autorização atual.

Repositório compartilha Dio/Identity/cancelamento, sem login paralelo. Stores por rota descartam resposta antiga/conta anterior, deduplicam páginas, respeitam Retry-After central e preservam a chave de intenção após timeout. Sem otimismos de confirmação/vaga; conflitos exigem leitura atual. Lifecycle/background/saída/troca de conta limpam dados e códigos transitórios. Detalhe privado de convidado também expira em até60s e revalida após ação/resume; operações próprias que retiram acesso atualizam o detalhe imediatamente. A validade é calculada por intervalo recebido do servidor, sem confiar no relógio civil do aparelho.

Tema claro/escuro, tipografia/cores Material3 Flow, cards compactos e Wrap/rolagem horizontal para ações/filtros; loading, vazio, erro/retry, sucesso e indisponibilidade explícitos. Confirmação contextual antes de cancelamento/remoção/bloqueio. Check-in não acrescenta permissão de câmera/GPS. Aviso de ingresso externo nos detalhes, agenda e check-in quando aplicável. CONFIRMED/check-in nunca confirmam pagamento.

## Operação e limites

| Variável | Default / limites |
| --- | --- |
| PARTICIPATION_MUTATION_MINUTE |30 por ator/minuto;5..120; tentativas recusadas também contam |
| CHECKIN_TTL_SECONDS |120;30..300; nunca além do fim |
| CHECKIN_LEAD_MINUTES |30 antes do início;0..120; fim encerra janela |

Defaults validados no startup, Compose/env.example preparados; chave HMAC derivada com domínio próprio da chave Identity existente, sem segredo novo no Flutter. O limite de origem Identity continua ativo. Banco é fonte de disponibilidade; ausência de vaga não cria waitlist. Participação de conta restrita não libera vaga silenciosamente; organizador pode remover de forma auditada.

`make experiences-maintenance` inclui lotes de até500: recibos após24h, códigos expirados há1 dia, quotas após2 dias, auditoria após180 dias. Sessão excluída também elimina sua credencial efêmera. Participações/convites/check-ins permanecem para histórico da relação e tratamento do agregado/conta; este PR não inventa expurgo automático de fatos pessoais ou apaga outbox pendente. Política de eliminação/contestação e calendário operacional de manutenção precisam ser aprovados para produção; não orientar suporte a editar banco/forçar estados.

## Validação e roteiro físico

```sh
make participation-test
make participation-mobile-contract
cd apps/mobile
../../flutterw analyze
../../flutterw test test/participation_test.dart
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

Testes reais usam somente `flow_experiences_test`/bucket `flow-experiences-test`, com guardas e rollback/up. FFmpeg/FFprobe continuam requisito dos testes de mídia anteriores. Nunca executar smoke em banco principal com dados. `make mobile-local` atualiza a API/migrations localmente, preservando volumes/configuração privada; Mac/iPhone na mesma rede. Nenhum fixture/test endpoint é compilado na aplicação.

Roteiro Android/iPhone físico com duas contas: criar PUBLIC/UNLISTED/PRIVATE; marcar interesse e solicitar/confirmar; disputar última vaga; aceitar/recusar/revogar convite; rejeitar/remover/bloquear; conferir atualização de agenda e perda de acesso privado. Na janela, emitir código no participante e digitar no organizador; testar rotação, expiração, replay, código de outra experiência, cancelamento durante conferência, sessão revogada e rede perdida após confirmar. Verificar que retry não duplica presença, que tema/texto ampliado são legíveis e que background/troca de conta não mantém nomes/códigos. Não há gate de câmera/QR neste protocolo. Homologação física, acessibilidade assistiva real e desempenho continuam separados dos testes automatizados/builds.
