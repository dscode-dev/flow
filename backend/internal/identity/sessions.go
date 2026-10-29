package identity

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"strings"
	"time"

	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

func (s *Service) Authenticate(ctx context.Context, access string) (*Session, error) {
	if !strings.HasPrefix(access, "fa_") {
		return nil, ErrUnauthorized
	}
	b, e := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(access, "fa_"))
	if e != nil || len(b) != 32 {
		return nil, ErrUnauthorized
	}
	found, e := s.q.FindAccessSession(ctx, digest(access))
	if errors.Is(e, pgx.ErrNoRows) {
		return nil, ErrUnauthorized
	}
	if e != nil {
		return nil, e
	}
	if found.Status != "active" {
		return nil, ErrRestricted
	}
	return &Session{ID: found.SID, UserID: found.SUserID, ReauthenticatedAt: found.ReauthenticatedAt.Time, ExpiresAt: found.ExpiresAt.Time}, nil
}
func (s *Service) issue(ctx context.Context, q *dbgen.Queries, session string, expiry time.Time) (Tokens, error) {
	access, refreshID, refreshSecret := "fa_"+secret(), newID(), secret()
	accessExpiry := time.Now().UTC().Add(s.config.AccessTTL)
	if accessExpiry.After(expiry) {
		accessExpiry = expiry
	}
	out := Tokens{AccessToken: access, TokenType: "Bearer", ExpiresIn: int64(time.Until(accessExpiry).Seconds()), RefreshToken: "fr_" + refreshID + "." + refreshSecret, SessionID: session, SessionExpiresAt: expiry.UTC()}
	if e := q.InsertRefreshCredential(ctx, dbgen.InsertRefreshCredentialParams{ID: id(refreshID), SessionID: id(session), CredentialHash: digest(refreshSecret), ExpiresAt: ts(expiry)}); e != nil {
		return Tokens{}, e
	}
	if e := q.InsertAccessCredential(ctx, dbgen.InsertAccessCredentialParams{CredentialHash: digest(access), SessionID: id(session), ExpiresAt: ts(accessExpiry)}); e != nil {
		return Tokens{}, e
	}
	return out, nil
}
func (s *Service) newSession(ctx context.Context, q *dbgen.Queries, user, method string, d Device, meta Metadata) (Tokens, error) {
	n, e := q.CountActiveSessions(ctx, id(user))
	if e != nil {
		return Tokens{}, e
	}
	if int(n) >= s.config.MaxSessions {
		return Tokens{}, ErrSessions
	}
	device, session, expiry := newID(), newID(), time.Now().UTC().Add(s.config.SessionTTL)
	if e = q.InsertIdentityDevice(ctx, dbgen.InsertIdentityDeviceParams{ID: id(device), UserID: id(user), Platform: d.Platform, AppVersion: d.AppVersion, Label: d.Label}); e != nil {
		return Tokens{}, e
	}
	if e = q.InsertIdentitySession(ctx, dbgen.InsertIdentitySessionParams{ID: id(session), UserID: id(user), DeviceID: id(device), AuthenticatedProvider: method, ExpiresAt: ts(expiry)}); e != nil {
		return Tokens{}, e
	}
	if e = event(ctx, q, user, "identity.session.created"); e != nil {
		return Tokens{}, e
	}
	if e = audit(ctx, q, user, session, "identity.session.created", "success", "", meta); e != nil {
		return Tokens{}, e
	}
	return s.issue(ctx, q, session, expiry)
}
func (s *Service) Refresh(ctx context.Context, raw string, meta Metadata) (LoginResult, error) {
	var out LoginResult
	selector, credential, ok := parseRefresh(raw)
	if !ok {
		return out, ErrCredential
	}
	owner, e := s.q.FindRefreshOwner(ctx, id(selector))
	if errors.Is(e, pgx.ErrNoRows) {
		return out, ErrCredential
	}
	if e != nil {
		return out, e
	}
	var rejected error
	e = s.transaction(ctx, func(q *dbgen.Queries) error {
		if _, e := lockActive(ctx, q, owner.SUserID); e != nil {
			return e
		}
		session, e := q.LockIdentitySession(ctx, id(owner.RSessionID))
		if e != nil {
			return e
		}
		token, e := q.LockRefreshCredential(ctx, dbgen.LockRefreshCredentialParams{ID: id(selector), SessionID: id(session.ID)})
		if e != nil {
			return e
		}
		if subtle.ConstantTimeCompare(token.CredentialHash, digest(credential)) != 1 {
			rejected = ErrCredential
			return audit(ctx, q, session.UserID, session.ID, "identity.refresh", "denied", "credential_mismatch", meta)
		}
		if token.UsedAt.Valid {
			rejected = ErrCredential
			if e = s.revoke(ctx, q, session.UserID, session.ID, "refresh_reuse", meta); e != nil {
				return e
			}
			return audit(ctx, q, session.UserID, session.ID, "identity.refresh", "denied", "refresh_reuse", meta)
		}
		if session.RevokedAt.Valid || !session.ExpiresAt.Time.After(time.Now()) || !token.ExpiresAt.Time.After(time.Now()) {
			rejected = ErrCredential
			return audit(ctx, q, session.UserID, session.ID, "identity.refresh", "denied", "session_unusable", meta)
		}
		if e = q.ConsumeRefreshCredential(ctx, id(selector)); e != nil {
			return e
		}
		if e = q.TouchIdentitySession(ctx, id(session.ID)); e != nil {
			return e
		}
		out.Tokens, e = s.issue(ctx, q, session.ID, session.ExpiresAt.Time)
		if e != nil {
			return e
		}
		out.User, e = me(ctx, q, session.UserID)
		return e
	})
	if e != nil {
		return LoginResult{}, e
	}
	if rejected != nil {
		return LoginResult{}, rejected
	}
	return out, nil
}
func (s *Service) revoke(ctx context.Context, q *dbgen.Queries, user, session, reason string, meta Metadata) error {
	n, e := q.RevokeIdentitySession(ctx, dbgen.RevokeIdentitySessionParams{ID: id(session), UserID: id(user), RevocationReason: text(reason)})
	if e != nil {
		return e
	}
	if n == 0 {
		return nil
	}
	if e = event(ctx, q, user, "identity.session.revoked"); e != nil {
		return e
	}
	return audit(ctx, q, user, session, "identity.session.revoked", "success", reason, meta)
}
func (s *Service) Revoke(ctx context.Context, current *Session, target string, all bool, meta Metadata) error {
	if !all && !validID(target) {
		return ErrInvalid
	}
	return s.transaction(ctx, func(q *dbgen.Queries) error {
		recent := s.config.RecentAuth
		if !all && current != nil && target == current.ID {
			recent = 0
		}
		if e := lockSession(ctx, q, current, recent); e != nil {
			return e
		}
		targets := []string{target}
		if all {
			var e error
			targets, e = q.ActiveUserSessionIDs(ctx, id(current.UserID))
			if e != nil {
				return e
			}
		}
		for _, target := range targets {
			if e := s.revoke(ctx, q, current.UserID, target, "user_request", meta); e != nil {
				return e
			}
		}
		return nil
	})
}

type SessionInfo struct {
	ID         string    `json:"id"`
	Current    bool      `json:"current"`
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	LastUsedAt time.Time `json:"last_used_at"`
	Device     Device    `json:"device"`
}

func (s *Service) Sessions(ctx context.Context, current *Session) ([]SessionInfo, error) {
	if current == nil {
		return nil, ErrUnauthorized
	}
	rows, e := s.q.ListIdentitySessions(ctx, id(current.UserID))
	if e != nil {
		return nil, e
	}
	out := []SessionInfo{}
	for _, r := range rows {
		out = append(out, SessionInfo{r.SID, r.SID == current.ID, r.CreatedAt.Time, r.ExpiresAt.Time, r.LastUsedAt.Time, Device{r.Platform, r.AppVersion, r.Label}})
	}
	return out, nil
}
