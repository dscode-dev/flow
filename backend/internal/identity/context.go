// Package identity implementa contas, provas de provedor e sessões do Flow.
package identity

import (
	"context"
)

type Principal struct {
	Subject     string
	Permissions []string
}
type Authenticator interface {
	Authenticate(context.Context, string) (*Session, error)
}
type Authorizer interface {
	Authorize(context.Context, Principal, string, string) error
}

var _ Authenticator = (*Service)(nil)

// Authorizer fica reservado para permissões de domínios futuros. Neste ciclo,
// ownership, status e autenticação recente são impostos pelo serviço Identity.
