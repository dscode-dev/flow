// Package identity define apenas o contrato de identidade. Não valida tokens no PR-00.
package identity

import (
	"context"
	"net/http"
)

type Principal struct {
	Subject     string
	Permissions []string
}
type Authenticator interface {
	Authenticate(context.Context, *http.Request) (Principal, error)
}
type Authorizer interface {
	Authorize(context.Context, Principal, string, string) error
}

// Adaptadores serão injetados em rotas protegidas no PR-01; ausência de adaptador
// jamais concede acesso. Health/readiness são as únicas rotas atuais.
