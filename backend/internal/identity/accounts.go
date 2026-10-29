package identity

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/text/unicode/norm"
)

func cleanLabel(v string, max int) (string, error) {
	v = norm.NFC.String(strings.TrimSpace(v))
	if !utf8.ValidString(v) || utf8.RuneCountInString(v) > max {
		return "", ErrInvalid
	}
	for _, r := range v {
		if unicode.IsControl(r) || unicode.In(r, unicode.Cf) {
			return "", ErrInvalid
		}
	}
	return v, nil
}
func validateDevice(d Device) (Device, error) {
	if d.Platform != "android" && d.Platform != "ios" {
		return d, ErrInvalid
	}
	if !regexp.MustCompile(`^[0-9A-Za-z.+_-]{1,32}$`).MatchString(d.AppVersion) {
		return d, ErrInvalid
	}
	var e error
	d.Label, e = cleanLabel(d.Label, 80)
	return d, e
}
func me(ctx context.Context, q *dbgen.Queries, user string) (Me, error) {
	row, e := q.IdentityMe(ctx, id(user))
	if e != nil {
		return Me{}, e
	}
	out := Me{ID: row.UID, Status: row.Status, CreatedAt: row.CreatedAt.Time, OnboardingRequired: !row.OnboardingCompletedAt.Valid, Profile: Profile{DisplayName: row.DisplayName}}
	if row.Handle.Valid {
		out.Profile.Handle = &row.Handle.String
	}
	if row.AvatarRef.Valid {
		v := uuidText(row.AvatarRef)
		out.Profile.AvatarRef = &v
	}
	return out, nil
}
func (s *Service) Me(ctx context.Context, session *Session) (Me, error) {
	if session == nil {
		return Me{}, ErrUnauthorized
	}
	return me(ctx, s.q, session.UserID)
}

func (s *Service) Login(ctx context.Context, p Proof, d Device, meta Metadata) (LoginResult, error) {
	var out LoginResult
	d, e := validateDevice(d)
	if e != nil {
		return out, e
	}
	e = s.consume(ctx, p, "login", nil, meta, func(q *dbgen.Queries, subject string) error {
		found, e := q.FindProviderIdentity(ctx, dbgen.FindProviderIdentityParams{Provider: p.Provider, ProviderSubject: subject})
		user := ""
		if errors.Is(e, pgx.ErrNoRows) {
			user = newID()
			if e = q.CreateIdentityUser(ctx, id(user)); e != nil {
				return e
			}
			if e = q.CreateIdentityProfile(ctx, id(user)); e != nil {
				return e
			}
			if e = q.InsertProviderIdentity(ctx, dbgen.InsertProviderIdentityParams{ID: id(newID()), UserID: id(user), Provider: p.Provider, ProviderSubject: subject}); e != nil {
				return e
			}
			if e = event(ctx, q, user, "identity.user.created"); e != nil {
				return e
			}
			if e = event(ctx, q, user, "identity.provider.linked"); e != nil {
				return e
			}
		} else if e != nil {
			return e
		} else {
			user = found.UserID
			if found.RevokedAt.Valid {
				return ErrCredential
			}
		}
		if _, e = lockActive(ctx, q, user); e != nil {
			return e
		}
		if e = q.TouchAuthenticatedUser(ctx, id(user)); e != nil {
			return e
		}
		out.Tokens, e = s.newSession(ctx, q, user, p.Provider, d, meta)
		if e != nil {
			return e
		}
		out.User, e = me(ctx, q, user)
		return e
	})
	return out, e
}

func (s *Service) Onboarding(ctx context.Context, session *Session, displayName, handle string, meta Metadata) (Me, error) {
	var out Me
	displayName, e := cleanLabel(displayName, 80)
	if e != nil || displayName == "" {
		return out, ErrInvalid
	}
	handle = strings.ToLower(strings.TrimSpace(handle))
	if !regexp.MustCompile(`^[a-z][a-z0-9_]{2,29}$`).MatchString(handle) {
		return out, ErrInvalid
	}
	e = s.transaction(ctx, func(q *dbgen.Queries) error {
		if e := lockSession(ctx, q, session, 0); e != nil {
			return e
		}
		current, e := q.IdentityMe(ctx, id(session.UserID))
		if e != nil {
			return e
		}
		if current.OnboardingCompletedAt.Valid {
			if current.DisplayName == displayName && current.Handle.String == handle {
				out, e = me(ctx, q, session.UserID)
				return e
			}
			return ErrOnboarding
		}
		reserved, e := q.IsReservedHandle(ctx, handle)
		if e != nil {
			return e
		}
		if reserved {
			return ErrHandle
		}
		if e = q.CompleteIdentityOnboarding(ctx, dbgen.CompleteIdentityOnboardingParams{UserID: id(session.UserID), DisplayName: displayName, Handle: text(handle)}); e != nil {
			return e
		}
		if e = q.MarkIdentityOnboarding(ctx, id(session.UserID)); e != nil {
			return e
		}
		if e = audit(ctx, q, session.UserID, session.ID, "identity.onboarding.completed", "success", "", meta); e != nil {
			return e
		}
		out, e = me(ctx, q, session.UserID)
		return e
	})
	var pgErr *pgconn.PgError
	if errors.As(e, &pgErr) && pgErr.Code == "23505" {
		return Me{}, ErrHandle
	}
	return out, e
}

type LinkedIdentity struct {
	ID         string    `json:"id"`
	Provider   string    `json:"provider"`
	VerifiedAt time.Time `json:"verified_at"`
}

func (s *Service) Identities(ctx context.Context, session *Session) ([]LinkedIdentity, error) {
	if session == nil {
		return nil, ErrUnauthorized
	}
	rows, e := s.q.ListUserIdentities(ctx, id(session.UserID))
	if e != nil {
		return nil, e
	}
	out := []LinkedIdentity{}
	for _, r := range rows {
		out = append(out, LinkedIdentity{r.ID, r.Provider, r.VerifiedAt.Time})
	}
	return out, nil
}
func (s *Service) Link(ctx context.Context, session *Session, p Proof, meta Metadata) error {
	return s.consume(ctx, p, "link", session, meta, func(q *dbgen.Queries, subject string) error {
		existing, e := q.FindProviderIdentity(ctx, dbgen.FindProviderIdentityParams{Provider: p.Provider, ProviderSubject: subject})
		if e == nil {
			if existing.UserID != session.UserID {
				return ErrConflict
			}
			if !existing.RevokedAt.Valid {
				return nil
			}
			if e = q.RestoreProviderIdentity(ctx, id(existing.ID)); e != nil {
				return e
			}
		} else if errors.Is(e, pgx.ErrNoRows) {
			if e = q.InsertProviderIdentity(ctx, dbgen.InsertProviderIdentityParams{ID: id(newID()), UserID: id(session.UserID), Provider: p.Provider, ProviderSubject: subject}); e != nil {
				return e
			}
		} else {
			return e
		}
		if e = event(ctx, q, session.UserID, "identity.provider.linked"); e != nil {
			return e
		}
		return audit(ctx, q, session.UserID, session.ID, "identity.provider.linked", "success", "", meta)
	})
}
func (s *Service) Reauthenticate(ctx context.Context, session *Session, p Proof, meta Metadata) error {
	return s.consume(ctx, p, "reauth", session, meta, func(q *dbgen.Queries, subject string) error {
		found, e := q.FindProviderIdentity(ctx, dbgen.FindProviderIdentityParams{Provider: p.Provider, ProviderSubject: subject})
		if errors.Is(e, pgx.ErrNoRows) {
			return ErrCredential
		}
		if e != nil {
			return e
		}
		if found.UserID != session.UserID || found.RevokedAt.Valid {
			return ErrCredential
		}
		if e = q.ReauthenticateIdentitySession(ctx, dbgen.ReauthenticateIdentitySessionParams{ID: id(session.ID), AuthenticatedProvider: p.Provider}); e != nil {
			return e
		}
		return audit(ctx, q, session.UserID, session.ID, "identity.session.reauthenticated", "success", "", meta)
	})
}
func (s *Service) Unlink(ctx context.Context, session *Session, identityID string, meta Metadata) error {
	if !validID(identityID) {
		return ErrInvalid
	}
	return s.transaction(ctx, func(q *dbgen.Queries) error {
		if e := lockSession(ctx, q, session, s.config.RecentAuth); e != nil {
			return e
		}
		rows, e := q.ListUserIdentities(ctx, id(session.UserID))
		if e != nil {
			return e
		}
		target, usable := false, 0
		for _, r := range rows {
			if r.ID == identityID {
				target = true
				continue
			}
			if (r.Provider == "PHONE" && s.sms != nil) || s.tokens[r.Provider] != nil {
				usable++
			}
		}
		if !target {
			return nil
		}
		if usable == 0 {
			return ErrLastIdentity
		}
		if _, e = q.RevokeProviderIdentity(ctx, dbgen.RevokeProviderIdentityParams{ID: id(identityID), UserID: id(session.UserID)}); e != nil {
			return e
		}
		if e = event(ctx, q, session.UserID, "identity.provider.unlinked"); e != nil {
			return e
		}
		return audit(ctx, q, session.UserID, session.ID, "identity.provider.unlinked", "success", "", meta)
	})
}
