package identity

import (
	"context"
	"errors"

	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

func (s *Service) AppleNotification(ctx context.Context, raw string, meta Metadata) error {
	if s.apple == nil {
		return ErrUnavailable
	}
	ev, e := s.apple.Notification(ctx, raw)
	if e != nil {
		return ErrCredential
	}
	return s.transaction(ctx, func(q *dbgen.Queries) error {
		if e = q.IdentityAdvisoryLock(ctx, "identity:APPLE:"+ev.Subject); e != nil {
			return e
		}
		n, e := q.RegisterAppleNotification(ctx, digest("apple:"+ev.ID))
		if e != nil {
			return e
		}
		if n == 0 {
			return nil
		}
		found, e := q.FindProviderIdentity(ctx, dbgen.FindProviderIdentityParams{Provider: "APPLE", ProviderSubject: ev.Subject})
		if errors.Is(e, pgx.ErrNoRows) {
			return nil
		}
		if e != nil {
			return e
		}
		// Também processa revogação de contas suspensas; não depende de sessão mobile.
		if _, e = q.LockIdentityUser(ctx, id(found.UserID)); e != nil {
			return e
		}
		if ev.Type == "consent-revoked" || ev.Type == "account-deleted" {
			if _, e = q.RevokeProviderIdentity(ctx, dbgen.RevokeProviderIdentityParams{ID: id(found.ID), UserID: id(found.UserID)}); e != nil {
				return e
			}
			sessions, e := q.ActiveUserSessionIDs(ctx, id(found.UserID))
			if e != nil {
				return e
			}
			for _, sid := range sessions {
				if e = s.revoke(ctx, q, found.UserID, sid, "apple_revoked", meta); e != nil {
					return e
				}
			}
			if !found.RevokedAt.Valid {
				if e = event(ctx, q, found.UserID, "identity.provider.unlinked"); e != nil {
					return e
				}
			}
		}
		return audit(ctx, q, found.UserID, "", "identity.apple.notification", "success", ev.Type, meta)
	})
}
