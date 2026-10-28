# Auditoria inicial — PR-00

Data: 27/10/2026. Diretório examinado: workspace `Flow` informado na sessão.

## Evidências antes de alterar código

- `ls -la`: somente `.` e `..`; nenhum arquivo, inclusive oculto.
- `git status --short` e `git branch --show-current`: `fatal: not a git repository`.
- `rg --files` não encontrou arquivos, pubspec, README ou instruções AGENTS locais.
- Não há telas, rotas, widgets, estados, temas, dependências, Mapbox ou ativos de marca disponíveis para inspeção.
- Portanto não é possível classificar implementações preserváveis, pacotes obsoletos, duplicações ou código sem uso. Ausência de acesso não é evidência de ausência dessas funcionalidades no produto original.
- Ambiente instalado: Go 1.26.3; Flutter stable 3.41.9 com Dart 3.11.5; Docker Engine 29.7.2. Flutter e Docker exigem acesso fora do sandbox para cache/socket.

## Estratégia incremental e limitação

Foi solicitado o caminho/URL do legado. Até sua disponibilização, a fundação independente é criada neste workspace, sem inicializar Git, inventar telas antigas, substituir marca ou apresentar migração como concluída. A aplicação mobile adicionada é apenas uma base técnica explícita. Não há logo aprovado verificável; o nome textual Flow não o substitui.

O usuário forneceu `https://github.com/dscode-dev/flow.git` durante a execução. O clone em diretório temporário retornou `You appear to have cloned an empty repository`; `git ls-remote origin` não retornou referências e `git status --short --branch` mostrou `No commits yet on main`. A API conectada GitHub confirmou `size: 0`, branch padrão `main`. Os metadados desse clone foram associados ao workspace, sem commit ou push. Nenhum código legado foi encontrado também na origem fornecida.

Ao receber o legado: inventariar árvore e histórico, registrar fluxos críticos e permissões nativas, inspecionar marca e configuração Mapbox sem expor tokens, comparar dependências e licenças, executar baseline e migrar bootstrap, temas, estado e rotas em etapas. Preservar identificadores de bundle, links e dados locais. Testar cada fluxo afetado antes de mover arquivos. Não sobrepor automaticamente `apps/mobile` ao aplicativo existente.

## Pendências obrigatórias

Auditoria funcional, regressão do legado, Mapbox e branding permanecem bloqueados pelo código ausente. Não afirmar que PR-00 preservou ou modernizou uma aplicação que não foi fornecida.
