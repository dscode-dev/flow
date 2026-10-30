package identity

import (
	"context"

	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

// RequireCreator locks Identity's account/session in the caller's transaction.
// Account restrictions and revocation serialize with domain writes. Call before
// locking domain rows. Identity owns these queries; callers receive no profile
// or provider data. A completed onboarding is required to author content.
func RequireCreator(ctx context.Context, tx pgx.Tx, session *Session) error {
	q := dbgen.New(tx)
	if err := lockSession(ctx, q, session, 0); err != nil {
		return err
	}
	u, err := q.LockIdentityUser(ctx, id(session.UserID))
	if err != nil {
		return err
	}
	if !u.OnboardingCompletedAt.Valid {
		return ErrOnboardingRequired
	}
	return nil
}
