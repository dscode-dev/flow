package participation

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"time"

	"flow.local/backend/internal/experiences"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool   *pgxpool.Pool
	config Config
}

func New(pool *pgxpool.Pool, c Config) *Service { return &Service{pool, c} }
func id(s string) pgtype.UUID                   { u, e := uuid.Parse(s); return pgtype.UUID{Bytes: u, Valid: e == nil} }
func str(u pgtype.UUID) string                  { return uuid.UUID(u.Bytes).String() }
func newID() pgtype.UUID                        { return id(uuid.Must(uuid.NewV7()).String()) }
func ts(t time.Time) pgtype.Timestamptz         { return pgtype.Timestamptz{Time: t.UTC(), Valid: true} }

type state struct {
	e              experiences.Experience
	moderation     string
	mode           string
	version, count int64
	accessible     bool
	now            time.Time
	creatorActive  bool
}

func contextFor(ctx context.Context, q *dbgen.Queries, eid, user string) (state, error) {
	var s state
	r, err := q.ParticipationContext(ctx, dbgen.ParticipationContextParams{ExperienceID: id(eid), Viewer: id(user)})
	if errors.Is(err, pgx.ErrNoRows) {
		return s, identity.ErrNotFound
	}
	if err != nil {
		return s, err
	}
	if err = json.Unmarshal(r.Document, &s.e); err != nil {
		return s, err
	}
	var x struct {
		Moderation string `json:"moderation_status"`
	}
	if err = json.Unmarshal(r.Document, &x); err != nil {
		return s, err
	}
	s.moderation = x.Moderation
	s.mode = r.Mode
	s.version = r.SettingsVersion
	s.count = r.ConfirmedCount
	s.accessible = r.Accessible
	s.now = r.AsOf.Time.UTC()
	s.creatorActive = r.CreatorStatus == "active"
	return s, nil
}
func (s state) owner(user string) bool { return s.e.CreatorUserID == user }
func (s state) open() bool {
	return s.e.Status == "PUBLISHED" && s.moderation == "VISIBLE" && s.creatorActive && s.e.EndsAt != nil && s.e.EndsAt.After(s.now)
}
func (s state) settings() Settings {
	return Settings{s.mode, s.e.Capacity, s.count, s.version, s.e.Version, s.e.Visibility, s.open(), s.e.Status == "DRAFT" || s.open()}
}
func member(ctx context.Context, q *dbgen.Queries, eid, user string) (dbgen.ParticipationMember, error) {
	m, err := q.GetParticipationMember(ctx, dbgen.GetParticipationMemberParams{ExperienceID: id(eid), UserID: id(user)})
	if errors.Is(err, pgx.ErrNoRows) {
		return dbgen.ParticipationMember{ID: newID(), ExperienceID: id(eid), UserID: id(user), State: "NONE"}, nil
	}
	return m, err
}
func saveMember(ctx context.Context, q *dbgen.Queries, m dbgen.ParticipationMember) (dbgen.ParticipationMember, error) {
	return q.SaveParticipationMember(ctx, dbgen.SaveParticipationMemberParams{ID: m.ID, ExperienceID: m.ExperienceID, UserID: m.UserID, Interested: m.Interested, State: m.State, Blocked: m.Blocked})
}
func invitation(i dbgen.ParticipationInvitation, now time.Time) Invitation {
	return Invitation{str(i.ID), str(i.ExperienceID), str(i.InviteeUserID), i.State, i.ExpiresAt.Time, i.Version, !i.ExpiresAt.Time.After(now)}
}
func emit(ctx context.Context, q *dbgen.Queries, eid, actor, subject, action string, version int64, resource, state string, details any) error {
	raw, err := json.Marshal(details)
	if err != nil {
		return err
	}
	if err = q.InsertParticipationAudit(ctx, dbgen.InsertParticipationAuditParams{ID: newID(), ExperienceID: id(eid), ActorUserID: id(actor), SubjectUserID: id(subject), Action: action, ResourceVersion: version, RequestID: requestID(ctx), Details: raw}); err != nil {
		return err
	}
	payload, _ := json.Marshal(map[string]any{"experience_id": eid, "subject_user_id": subject, "resource_id": resource, "version": version, "state": state})
	return q.AppendOutbox(ctx, dbgen.AppendOutboxParams{EventID: newID(), EventType: action, SchemaVersion: 1, AggregateID: id(eid), OccurredAt: ts(time.Now()), Payload: payload})
}

type requestKey struct{}

func requestID(ctx context.Context) string { v, _ := ctx.Value(requestKey{}).(string); return v }

type command func(context.Context, pgx.Tx, *dbgen.Queries, state) (any, error)

// Identity lock precedes Experience lock everywhere; capacity/count/command receipt,
// mutation, audit and outbox share one transaction. Errors never publish facts.
func (s *Service) run(ctx context.Context, session *identity.Session, eid, key, operation, request string, input any, write bool, fn command) (json.RawMessage, error) {
	if session == nil {
		return nil, identity.ErrUnauthorized
	}
	if !id(eid).Valid || !id(session.UserID).Valid || (write && key != "" && !id(key).Valid) {
		return nil, ErrInvalid
	}
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, requestKey{}, request), 5*time.Second)
	defer cancel()
	if write {
		n, err := dbgen.New(s.pool).ParticipationRate(ctx, id(session.UserID))
		if err != nil {
			return nil, err
		}
		if n > int32(s.config.MutationMinute) {
			return nil, identity.ErrRate
		}
	}
	raw, _ := json.Marshal(struct {
		Experience, Operation string
		Input                 any
	}{eid, operation, input})
	hash := sha256.Sum256(raw)
	var response json.RawMessage
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if err := identity.RequireCreator(ctx, tx, session); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout='2s'"); err != nil {
			return err
		}
		q := dbgen.New(tx)
		if _, err := q.LockExperience(ctx, id(eid)); errors.Is(err, pgx.ErrNoRows) {
			return identity.ErrNotFound
		} else if err != nil {
			return err
		}
		current, err := contextFor(ctx, q, eid, session.UserID)
		if err != nil {
			return err
		}
		if !current.accessible {
			return identity.ErrNotFound
		}
		if write && key != "" {
			prior, err := q.ParticipationIdempotency(ctx, dbgen.ParticipationIdempotencyParams{ActorUserID: id(session.UserID), Key: id(key)})
			if err == nil {
				if !bytes.Equal(hash[:], prior.RequestHash) {
					return ErrKey
				}
				response = prior.Response
				return nil
			}
			if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		value, err := fn(ctx, tx, q, current)
		if err != nil {
			return err
		}
		response, err = json.Marshal(value)
		if err != nil {
			return err
		}
		if write && key != "" {
			return q.SaveParticipationIdempotency(ctx, dbgen.SaveParticipationIdempotencyParams{ActorUserID: id(session.UserID), Key: id(key), RequestHash: hash[:], Response: response})
		}
		return nil
	})
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.ConstraintName == "participation_capacity" {
		return nil, ErrFull
	}
	return response, err
}
func summary(ctx context.Context, q *dbgen.Queries, current state, user string, c Config) (Summary, error) {
	m, err := member(ctx, q, current.e.ID, user)
	if err != nil {
		return Summary{}, err
	}
	out := Summary{ExperienceID: current.e.ID, Mode: current.mode, State: m.State, Interested: m.Interested, Version: m.Version, IsOwner: current.owner(user), Eligible: current.open(), Capacity: current.e.Capacity, ConfirmedCount: current.count, Actions: []string{}, ExternalTicket: current.e.ExternalTicketURL != nil, AsOf: current.now, ValidUntil: current.now.Add(time.Minute)}
	out.CheckinOpen = current.open() && current.e.StartsAt != nil && !current.now.Before(current.e.StartsAt.Add(-time.Duration(c.CheckinLeadMinutes)*time.Minute))
	if current.e.Capacity != nil {
		v := max(0, *current.e.Capacity-int32(current.count))
		out.Remaining = &v
	}
	if current.e.StartsAt != nil && current.e.EndsAt != nil {
		for _, boundary := range []time.Time{*current.e.StartsAt, current.e.StartsAt.Add(-time.Duration(c.CheckinLeadMinutes) * time.Minute), *current.e.EndsAt} {
			if boundary.After(current.now) && boundary.Before(out.ValidUntil) {
				out.ValidUntil = boundary
			}
		}
	}
	if ci, err := q.GetParticipationCheckin(ctx, dbgen.GetParticipationCheckinParams{ExperienceID: id(current.e.ID), UserID: id(user)}); err == nil {
		out.CheckedIn = !ci.RevokedAt.Valid && m.State == "CONFIRMED" && current.e.Status == "PUBLISHED"
		if out.CheckedIn {
			t := ci.CheckedAt.Time
			out.CheckedAt = &t
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	i, err := q.GetParticipationInvitation(ctx, dbgen.GetParticipationInvitationParams{ExperienceID: id(current.e.ID), InviteeUserID: id(user)})
	if err == nil {
		v := invitation(i, current.now)
		out.Invitation = &v
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	if out.IsOwner {
		out.Actions = append(out.Actions, "manage")
		return out, nil
	}
	if !out.Eligible || m.Blocked {
		return out, nil
	}
	if m.Interested {
		out.Actions = append(out.Actions, "uninterest")
	} else {
		out.Actions = append(out.Actions, "interest")
	}
	if m.State == "CONFIRMED" || m.State == "PENDING" {
		out.Actions = append(out.Actions, "cancel")
	}
	if (m.State == "NONE" || m.State == "CANCELLED") && current.e.Visibility != "PRIVATE" {
		switch current.mode {
		case "FREE":
			out.Actions = append(out.Actions, "confirm")
		case "APPROVAL":
			out.Actions = append(out.Actions, "request")
		}
	}
	if out.Invitation != nil && out.Invitation.State == "PENDING" && !out.Invitation.Expired {
		out.Actions = append(out.Actions, "accept_invitation", "decline_invitation")
	}
	if m.State == "CONFIRMED" && current.e.StartsAt != nil && !current.now.Before(current.e.StartsAt.Add(-time.Duration(c.CheckinLeadMinutes)*time.Minute)) && !out.CheckedIn {
		out.Actions = append(out.Actions, "checkin_credential")
	}
	return out, nil
}
func (s *Service) Summary(ctx context.Context, a *identity.Session, eid string) (json.RawMessage, error) {
	return s.run(ctx, a, eid, "", "summary", "", nil, false, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		return summary(ctx, q, c, a.UserID, s.config)
	})
}
func (s *Service) Settings(ctx context.Context, a *identity.Session, eid string) (Settings, error) {
	var out Settings
	r, err := s.run(ctx, a, eid, "", "settings", "", nil, false, func(_ context.Context, _ pgx.Tx, _ *dbgen.Queries, c state) (any, error) {
		if !c.owner(a.UserID) {
			return nil, identity.ErrNotFound
		}
		return c.settings(), nil
	})
	if err == nil {
		err = json.Unmarshal(r, &out)
	}
	return out, err
}
func (s *Service) Configure(ctx context.Context, a *identity.Session, eid, expected string, in SettingsInput, request string) (Settings, error) {
	var out Settings
	if in.Mode != "FREE" && in.Mode != "APPROVAL" && in.Mode != "INVITE" {
		return out, ErrInvalid
	}
	if in.Capacity != nil && (*in.Capacity < 1 || *in.Capacity > 1000000) {
		return out, ErrInvalid
	}
	if expected == "" {
		return out, ErrPrecondition
	}
	r, err := s.run(ctx, a, eid, "", "settings.update", request, in, true, func(ctx context.Context, tx pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if !c.owner(a.UserID) {
			return nil, identity.ErrNotFound
		}
		if c.e.Visibility == "PRIVATE" && in.Mode != "INVITE" {
			return nil, ErrPrivate
		}
		if expected != c.settings().ETag() {
			return nil, ErrVersion
		}
		if c.e.Status != "DRAFT" && !c.open() {
			return nil, ErrState
		}
		if in.Capacity != nil && int64(*in.Capacity) < c.count {
			return nil, ErrCapacity
		}
		old, _ := json.Marshal(c.e.Capacity)
		next, _ := json.Marshal(in.Capacity)
		if c.mode == in.Mode && bytes.Equal(old, next) {
			return c.settings(), nil
		}
		if !bytes.Equal(old, next) {
			if err := experiences.ChangeCapacity(ctx, tx, eid, a.UserID, in.Capacity, request); err != nil {
				return nil, err
			}
		}
		if err := q.SaveParticipationSettings(ctx, dbgen.SaveParticipationSettingsParams{ExperienceID: id(eid), Mode: in.Mode}); err != nil {
			return nil, err
		}
		updated, err := contextFor(ctx, q, eid, a.UserID)
		if err != nil {
			return nil, err
		}
		if err = emit(ctx, q, eid, a.UserID, a.UserID, "participation.settings_updated", updated.version, eid, in.Mode, in); err != nil {
			return nil, err
		}
		return updated.settings(), nil
	})
	if err == nil {
		err = json.Unmarshal(r, &out)
	}
	return out, err
}
