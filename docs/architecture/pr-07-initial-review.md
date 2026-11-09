# PR-07 — inspeção inicial

09/11/2026, America/Recife. Branch `main`, HEAD `8f13da50397761baca1e88960fd4fe3e1667c0b3` (`implementa PR-06`), índice e árvore limpos. Nenhum AGENTS.md aplicável encontrado. Relatório PR-06, Identity/transport/sessões/perfis, Experiences/Participation/ACL, migrations00001–00008, sqlc, OpenAPI, S3/FFmpeg/worker/streaming, governança e capacidades administrativas examinados antes das alterações. Social anterior era apenas o adaptador de autenticação OIDC, sem feed/graph/posts.

Flutter usa Riverpod, Dio central, go_router, Material3/Flow, store por rota com cancelamento/TTL e player nativo serializado. Reutilizar esses mecanismos e o pipeline Media, sem novo serviço. `avatar_ref` Identity não oferece distribuição de avatar validada para este módulo; avatar e bio não serão inventados. Experiências privadas/não listadas e opt-in Flows não habilitam exposição Social. Configuração de deep link de produção aprovada não existe; sem compartilhamento externo provisório.

Snapshot OpenAPI/HEAD inicial em `/private/tmp/flow-pr07-initial-*`, sem segredos. Testes transacionais usarão somente `flow_experiences_test` e bucket `flow-experiences-test`. SDK fixado no projeto, preservando tokens/configurações privadas, conta temporária e assinatura pessoal. Sem autorização para commit, push, merge ou deploy externo.
