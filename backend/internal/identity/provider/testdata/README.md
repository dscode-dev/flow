# Chave exclusivamente de teste

`test-only-rsa.pem` é uma fixture pública de testes automatizados. Não é credencial de Google, Apple ou Flow e nunca é lida pelo runtime. Serve para produzir assinaturas RS256 determinísticas com claims/relógio controlados; nenhuma chave real deve ser colocada aqui.
