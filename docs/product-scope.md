# Escopo Flow V1

Flow conecta descoberta de experiências, pessoas e conteúdo a contextos de eventos. O destino geográfico oficial é **Radar**. Marca aprovada: símbolo estilizado e nome Flow; arquivos finais ainda não foram fornecidos. Não criar logo substituto.

PR-00 entrega fundação técnica, contratos operacionais, arquitetura, privacidade e registro administrativo. Base mobile é nova pois origem fornecida está vazia; não afirmar preservação de Rolezin. Não entrega welcome/registro/login, CRUD, mapa, experiências, conteúdo, chat, notificações, admin ou transferência P2P.

Decisão de produto PR-01.A: Flow é implementação nova, sem recuperar ou migrar legado (ADR 0005). PR-01.A entrega backend de identidade com PHONE/SMS OTP, GOOGLE e APPLE, sessões, perfil mínimo/onboarding e vínculo seguro; sem senha ou telefone obrigatório após social. PR-01.B implementa Welcome, telefone/OTP, Google oficial, Apple nativo iOS, sessão segura, onboarding e shell de desenvolvimento sobre os contratos reais. Configuração e homologação externa, logo final e URLs legais aprovadas permanecem pendentes; ver features/mobile-authentication.md. Não há login fictício, usuário embutido ou dados de demonstração em widgets.

V1 inclui módulos descritos em `architecture/module-boundaries.md`. P2P é obrigatório em V1 exclusivamente para mídia social, nunca substitui origem durável ou ACL do servidor. Features serão detalhadas em ciclos próprios; fronteiras de módulos não são promessa de endpoints, cronograma ou serviços separados.

Critérios globais: acessibilidade, minimização de localização, respeito à audiência, autorização por recurso no servidor, compatibilidade mobile/backend e rastreabilidade de operações administrativas. Segurança técnica não estabelece conformidade LGPD.
