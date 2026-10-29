# Revisão inicial — PR-01.C

29/10/2026. Branch main, origin/main, HEAD `7b6225629234ef9e38b1bf95a321b6ff0b2b97ce` (implementa PR-01.B), workspace limpo. Relatórios PR-01.A/B, integração mobile, OpenAPI, fontes de identidade Flutter/Go, manifests/entitlements/signing, Compose/.env.example e CI inspecionados antes de alterações.

Proprietário confirmou nesta execução que IDs finais, providers, origem HTTPS, URLs legais e ativos aprovados ainda não existem. Arquivo .env local e ambiente do processo auditados somente por presença: Twilio/Google/Apple ausentes; HMAC local presente. Auth.local.xcconfig ausente. Não há logo aprovado no repositório. Não inventar valores nem repetir solicitação de credenciais.

A suíte anterior e builds são históricos, não homologação. CI remoto será consultado no HEAD exato; workspace novo exigirá execução posterior pelo proprietário após commit/push autorizado.

Achados a reproduzir/corrigir dentro da autenticação: publicação síncrona do estado refreshing antes de registrar o single-flight permite reentrada; logout interpreta qualquer 401 como revogação, embora também signifique access expirado; revalidação precisa conferir geração depois da consulta Apple. Revisão de observação nativa de revogação Apple e armazenamento/retomada permanece no escopo.

PostgreSQL real será usado em flow_identity_test; fornecedores controlados no harness serão identificados como fixtures locais. Nenhuma resposta de teste será chamada de homologação real. Nenhuma alteração de marca, app ID, assinatura ou configuração externa sem valores aprovados; sem commit/push/merge/deploy.
