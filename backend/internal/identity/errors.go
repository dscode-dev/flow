package identity

import "errors"

type Failure struct {
	Code   string
	Status int
}

func (e *Failure) Error() string { return e.Code }

var (
	ErrInvalid            = &Failure{"invalid_request", 400}
	ErrCredential         = &Failure{"invalid_credential", 401}
	ErrUnauthorized       = &Failure{"unauthorized", 401}
	ErrRestricted         = &Failure{"account_restricted", 403}
	ErrRecent             = &Failure{"reauthentication_required", 403}
	ErrConflict           = &Failure{"identity_conflict", 409}
	ErrLastIdentity       = &Failure{"last_identity", 409}
	ErrHandle             = &Failure{"handle_unavailable", 409}
	ErrOnboarding         = &Failure{"onboarding_already_completed", 409}
	ErrOnboardingRequired = &Failure{"onboarding_required", 403}
	ErrSessions           = &Failure{"session_limit", 409}
	ErrNotFound           = &Failure{"not_found", 404}
	ErrRate               = &Failure{"rate_limited", 429}
	ErrUnavailable        = &Failure{"provider_unavailable", 503}
	ErrStorage            = &Failure{"temporarily_unavailable", 503}
)

func SafeFailure(err error) *Failure {
	var f *Failure
	if errors.As(err, &f) {
		return f
	}
	return ErrStorage
}
