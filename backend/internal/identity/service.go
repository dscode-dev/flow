package identity

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"flow.local/backend/internal/identity/provider"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool   *pgxpool.Pool
	q      *dbgen.Queries
	config Config
	sms    provider.SMS
	tokens map[string]provider.TokenVerifier
	apple  provider.AppleNotifications
}
type Metadata struct{ Origin, RequestID string }
type Session struct {
	ID, UserID                   string
	ReauthenticatedAt, ExpiresAt time.Time
}
type Device struct {
	Platform   string `json:"platform"`
	AppVersion string `json:"app_version"`
	Label      string `json:"label"`
}
type Tokens struct {
	AccessToken      string    `json:"access_token"`
	TokenType        string    `json:"token_type"`
	ExpiresIn        int64     `json:"expires_in"`
	RefreshToken     string    `json:"refresh_token"`
	SessionID        string    `json:"session_id"`
	SessionExpiresAt time.Time `json:"session_expires_at"`
}
type Profile struct {
	DisplayName string  `json:"display_name"`
	Handle      *string `json:"handle"`
	AvatarRef   *string `json:"avatar_ref"`
}
type Me struct {
	ID                 string    `json:"id"`
	Status             string    `json:"status"`
	CreatedAt          time.Time `json:"created_at"`
	OnboardingRequired bool      `json:"onboarding_required"`
	Profile            Profile   `json:"profile"`
}
type LoginResult struct {
	Tokens Tokens `json:"tokens"`
	User   Me     `json:"user"`
}
type Proof struct {
	Provider    string `json:"provider"`
	ChallengeID string `json:"challenge_id"`
	Credential  string `json:"credential"`
}

func NewService(ctx context.Context, pool *pgxpool.Pool, c Config) *Service {
	s := &Service{pool: pool, q: dbgen.New(pool), config: c, tokens: map[string]provider.TokenVerifier{}}
	if c.TwilioAccountSID != "" {
		s.sms = provider.NewTwilio(c.TwilioAccountSID, c.TwilioAuthToken, c.TwilioServiceSID)
	}
	if len(c.GoogleClientIDs) > 0 {
		s.tokens["GOOGLE"] = provider.NewGoogle(ctx, c.GoogleClientIDs)
	}
	if len(c.AppleClientIDs) > 0 {
		a := provider.NewApple(ctx, c.AppleClientIDs)
		s.tokens["APPLE"] = a
		s.apple = a
	}
	return s
}
func (s *Service) Origin(remote string) string { return s.config.Origin(remote) }
func id(v string) pgtype.UUID                  { u, e := uuid.Parse(v); return pgtype.UUID{Bytes: u, Valid: e == nil} }
func uuidText(v pgtype.UUID) string {
	if !v.Valid {
		return ""
	}
	return uuid.UUID(v.Bytes).String()
}
func ts(v time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: v.UTC(), Valid: true} }
func text(v string) pgtype.Text         { return pgtype.Text{String: v, Valid: v != ""} }
func (s *Service) transaction(ctx context.Context, fn func(*dbgen.Queries) error) error {
	return database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error { return fn(s.q.WithTx(tx)) })
}
func (s *Service) OriginLimit(ctx context.Context, meta Metadata) error {
	return s.limit(ctx, []bucket{{"http:" + meta.Origin, time.Minute, s.config.OriginMinute}})
}
func audit(ctx context.Context, q *dbgen.Queries, user, session, action, outcome, reason string, meta Metadata) error {
	return q.InsertIdentityAudit(ctx, dbgen.InsertIdentityAuditParams{ID: id(newID()), UserID: id(user), SessionID: id(session), Action: action, Outcome: outcome, Reason: reason, RequestID: meta.RequestID})
}
func event(ctx context.Context, q *dbgen.Queries, user, eventType string) error {
	// IDs e versão somente. Nenhum subject do provedor ou segredo no payload.
	payload, _ := json.Marshal(map[string]string{"user_id": user})
	return q.AppendOutbox(ctx, dbgen.AppendOutboxParams{EventID: id(newID()), EventType: eventType, SchemaVersion: 1, AggregateID: id(user), OccurredAt: ts(time.Now()), Payload: payload})
}
func (s *Service) denied(ctx context.Context, meta Metadata, user, session, action, reason string) error {
	return audit(ctx, s.q, user, session, action, "denied", reason, meta)
}
func lockActive(ctx context.Context, q *dbgen.Queries, user string) (dbgen.LockIdentityUserRow, error) {
	u, e := q.LockIdentityUser(ctx, id(user))
	if errors.Is(e, pgx.ErrNoRows) {
		return u, ErrUnauthorized
	}
	if e != nil {
		return u, e
	}
	if u.Status != "active" {
		return u, ErrRestricted
	}
	return u, nil
}
func lockSession(ctx context.Context, q *dbgen.Queries, session *Session, recent time.Duration) error {
	if session == nil {
		return ErrUnauthorized
	}
	if _, e := lockActive(ctx, q, session.UserID); e != nil {
		return e
	}
	current, e := q.LockIdentitySession(ctx, id(session.ID))
	if e != nil {
		return e
	}
	if current.UserID != session.UserID || current.RevokedAt.Valid || !current.ExpiresAt.Time.After(time.Now()) {
		return ErrUnauthorized
	}
	if recent > 0 && time.Since(current.ReauthenticatedAt.Time) > recent {
		return ErrRecent
	}
	return nil
}
