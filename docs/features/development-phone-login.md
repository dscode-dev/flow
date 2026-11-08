# Acesso temporário por telefone — desenvolvimento

Implementado a pedido do proprietário para testar o app pelo fluxo normal de telefone/código. Não envia SMS para o único número explicitamente configurado. A conta, challenge, tentativas, sessão, refresh, onboarding, restrições e logout são os reais do Identity/PostgreSQL; não há usuário fake no Flutter, token inventado no cliente ou endpoint novo.

## Configuração e uso

Somente no `.env` local ignorado pelo Git:

```dotenv
FLOW_ENV=development
AUTH_DEVELOPMENT_PHONE_ENABLED=true
AUTH_DEVELOPMENT_PHONE_NUMBER=<telefone E.164 aprovado para teste>
AUTH_DEVELOPMENT_SMS_CODE=<código de seis dígitos aprovado para teste>
```

O número/código específicos solicitados foram configurados no ambiente local, sem serem embutidos no app, imagem Docker, exemplo público ou documentação versionada. O parser exige número válido nos países permitidos e código de seis dígitos. Flag desativada por padrão; true exige FLOW_ENV explicitamente development ou test. Produção, ambiente vazio ou desconhecido são recusados antes de iniciar a API. A configuração interna habilitadora só é construída por esse parser.

Na raiz, `make mobile-local` reconstrói/inicia a API e gera `apps/mobile/config/device.local.json`, com URL real e apenas a flag pública visual `DEVELOPMENT_PHONE_LOGIN_ENABLED`. Dentro de `apps/mobile`:

```sh
../../flutterw run --release --dart-define-from-file=config/device.local.json
```

O build release pode ser usado no iPhone com FLOW_ENV=development; modo de compilação não é ambiente produtivo. Mac/iPhone precisam estar na mesma rede, Docker ligado e Rede Local permitida. Produção não aceita essa flag visual no preflight e o app não mostra instruções de teste quando FLOW_ENV=production.

Fluxo: Continuar com telefone → número com DDD (Brasil +55) → Solicitar código → aguardar challenge → digitar código de teste → Confirmar código → aguardar validação/persistência da sessão → onboarding no primeiro acesso → Minhas experiências. Não há autofill do código nem navegação liberada antes da confirmação. Código incorreto mantém a etapa OTP; aguardar resposta impede toques duplicados. Não esperar SMS real neste modo.

## Limites e isolamento

O provedor local só intercepta o número permitido. Outros números continuam no Twilio configurado, ou indisponíveis sem Twilio; o código fixo não valida referências de outros provedores. Challenge mantém uso único, expiração, tentativas/cooldown/quotas e vínculo de identidade normais. O provedor de teste é exclusivo de login; não concede vinculação ou reautenticação privilegiada.

Referência opaca de entrega tem nonce aleatório e HMAC com domínio separado, ligada à configuração; sobrevive a restart sem armazenar telefone/código em claro no challenge. Trocar telefone/código/chave invalida referências anteriores. Código não é OTP de provedor real; SMS/OAuth reais continuam dependendo de homologação própria. Startup avisa somente que o modo está habilitado, sem imprimir valores.

Para desativar novas entradas, definir AUTH_DEVELOPMENT_PHONE_ENABLED=false e executar make mobile-local; reconstruir app para atualizar a indicação visual. Sessões já emitidas seguem as regras normais de expiração/revogação: sair da conta para encerrar uma sessão. Desabilitar a flag não apaga usuário/experiências nem comprova revogação de todas as sessões. A conta é persistente no banco de desenvolvimento até uma operação de eliminação autorizada; “temporário” refere-se ao acesso de teste habilitado por configuração, não a um job de apagamento automático.

## Evidências

Testes do provedor cobrem número exato, código errado/certo, referência adulterada, isolamento do fallback e restart. Parser recusa habilitação produtiva. Integração HTTP/OpenAPI/PostgreSQL cobre usuário inexistente antes de confirmar, código incorreto, uso único, sessão real, onboarding, refresh/logout e zero chamadas Twilio. Widget cobre espera do challenge e da confirmação, recusa do código errado e abertura somente após resposta válida. Auditoria de release e preflight recusam a flag de desenvolvimento em produção.

Telefone/código em `.env` têm acesso local restrito; número entra nas tabelas Identity somente como referência HMAC, conforme inventário existente. A configuração não autoriza suporte a acessar dados privados, obter tokens ou criar contas de terceiros.

Execução local em 07/11/2026: Go vet/test Identity aprovados; integração Identity/PostgreSQL completa aprovada (6,206s), incluindo o novo teste temporário; 41 testes Flutter de telas/sessão com indicação de teste ativa, análise sem issues e 16 testes Python aprovados. Smoke na API local confirmou challenge201, código errado401, código correto200, perfil200, logout204 e acesso posterior401; a sessão do smoke foi encerrada. iPhone conectado: release compilado (123,2s), instalado e iniciado com sucesso (3,9s), sem telefone/código em Dart defines. Digitação física e conclusão do perfil pelo proprietário não foram automatizadas.
