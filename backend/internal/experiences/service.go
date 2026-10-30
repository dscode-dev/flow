package experiences

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool   *pgxpool.Pool
	media  *media.Service
	config Config
}

func New(pool *pgxpool.Pool, m *media.Service, c Config) *Service { return &Service{pool, m, c} }
func id(v string) pgtype.UUID                                     { u, e := uuid.Parse(v); return pgtype.UUID{Bytes: u, Valid: e == nil} }
func newID() pgtype.UUID                                          { return pgtype.UUID{Bytes: uuid.Must(uuid.NewV7()), Valid: true} }
func ts(t time.Time) pgtype.Timestamptz                           { return pgtype.Timestamptz{Time: t.UTC(), Valid: true} }
func decodeRecord(raw []byte) (record, error) {
	var r record
	e := json.Unmarshal(raw, &r)
	return r, e
}
func load(ctx context.Context, q *dbgen.Queries, experienceID string) (record, error) {
	var r record
	data, e := q.GetExperience(ctx, id(experienceID))
	if errors.Is(e, pgx.ErrNoRows) {
		return r, identity.ErrNotFound
	}
	if e != nil {
		return r, e
	}
	return decodeRecord(data)
}
func emit(ctx context.Context, q *dbgen.Queries, e Experience, actor, action, requestID string) error {
	if err := q.InsertExperienceAudit(ctx, dbgen.InsertExperienceAuditParams{ID: newID(), ExperienceID: id(e.ID), ActorUserID: id(actor), Action: action, Version: e.Version, RequestID: requestID}); err != nil {
		return err
	}
	payload, _ := json.Marshal(map[string]any{"experience_id": e.ID, "version": e.Version, "status": e.Status, "visibility": e.Visibility})
	return q.AppendOutbox(ctx, dbgen.AppendOutboxParams{EventID: newID(), EventType: action, SchemaVersion: 1, AggregateID: id(e.ID), OccurredAt: ts(time.Now()), Payload: payload})
}
func save(ctx context.Context, q *dbgen.Queries, e Experience) (Experience, error) {
	raw, err := json.Marshal(e)
	if err != nil {
		return Experience{}, err
	}
	if err = q.SaveExperience(ctx, dbgen.SaveExperienceParams{Data: raw, NextVersion: e.Version, ID: id(e.ID)}); err != nil {
		return Experience{}, err
	}
	r, err := load(ctx, q, e.ID)
	return r.Experience, err
}
func category(ctx context.Context, q *dbgen.Queries, value *string) error {
	if value == nil {
		return nil
	}
	_, e := q.EnabledExperienceCategory(ctx, *value)
	if errors.Is(e, pgx.ErrNoRows) {
		return ErrValidation
	}
	return e
}
func (s *Service) quota(ctx context.Context, q *dbgen.Queries, owner, operation string, limit int) error {
	count, e := q.ExperienceRate(ctx, dbgen.ExperienceRateParams{OwnerUserID: id(owner), Operation: operation})
	if e != nil {
		return e
	}
	if int(count) > limit {
		return identity.ErrRate
	}
	return nil
}
func (s *Service) publishingAllowed(ctx context.Context, q *dbgen.Queries, owner string) error {
	restricted, e := q.ExperiencePublishingRestricted(ctx, id(owner))
	if e != nil {
		return e
	}
	if restricted {
		return ErrPublishing
	}
	return nil
}
func (s *Service) Create(ctx context.Context, session *identity.Session, key string, in Input, requestID string) (Experience, error) {
	var out Experience
	if !id(key).Valid {
		return out, ErrInvalid
	}
	in, e := normalized(in)
	if e != nil {
		return out, e
	}
	raw, _ := json.Marshal(in)
	hash := sha256.Sum256(raw)
	e = database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, session); e != nil {
			return e
		}
		q := dbgen.New(tx)
		prior, e := q.ExperienceIdempotency(ctx, dbgen.ExperienceIdempotencyParams{CreatorUserID: id(session.UserID), Key: id(key)})
		if e == nil {
			if !bytes.Equal(prior.RequestHash, hash[:]) {
				return ErrIdempotency
			}
			return json.Unmarshal(prior.Response, &out)
		}
		if !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
		if e = q.DeleteExpiredExperienceKey(ctx, dbgen.DeleteExpiredExperienceKeyParams{CreatorUserID: id(session.UserID), Key: id(key)}); e != nil {
			return e
		}
		if e = s.quota(ctx, q, session.UserID, "create", s.config.CreateDaily); e != nil {
			return e
		}
		drafts, e := q.ExperienceDraftCount(ctx, id(session.UserID))
		if e != nil {
			return e
		}
		if drafts >= int64(s.config.MaxDrafts) {
			return ErrDraftLimit
		}
		if e = category(ctx, q, in.CategoryID); e != nil {
			return e
		}
		eid := newID()
		out = Experience{Input: in, ID: uuid.UUID(eid.Bytes).String(), CreatorUserID: session.UserID, Status: "DRAFT", LocationType: "PHYSICAL", Version: 1}
		if e = q.InsertExperience(ctx, dbgen.InsertExperienceParams{ID: eid, CreatorUserID: id(session.UserID)}); e != nil {
			return e
		}
		if e = s.media.Bind(ctx, tx, out.ID, session.UserID, in.CoverMediaID); e != nil {
			return e
		}
		out, e = save(ctx, q, out)
		if e != nil {
			return e
		}
		if e = emit(ctx, q, out, session.UserID, "experience.created", requestID); e != nil {
			return e
		}
		response, _ := json.Marshal(out)
		return q.InsertExperienceIdempotency(ctx, dbgen.InsertExperienceIdempotencyParams{CreatorUserID: id(session.UserID), Key: id(key), RequestHash: hash[:], ExperienceID: eid, Response: response})
	})
	return out, e
}
func protectedEqual(a, b Input) bool {
	for _, p := range []*Input{&a, &b} {
		p.Title = ""
		p.Description = ""
		p.ExternalTicketURL = nil
		p.CoverMediaID = nil
	}
	aa, _ := json.Marshal(a)
	bb, _ := json.Marshal(b)
	return bytes.Equal(aa, bb)
}

// mutate serializes owner/session eligibility, version and domain invariants.
// Requests from another owner receive 404 before version/state are examined.
func (s *Service) mutate(ctx context.Context, session *identity.Session, eid string, version int64, action, requestID string, fn func(context.Context, pgx.Tx, *dbgen.Queries, *record) (bool, error)) (Experience, error) {
	var out Experience
	if !id(eid).Valid {
		return out, ErrInvalid
	}
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, session); e != nil {
			return e
		}
		q := dbgen.New(tx)
		if _, e := q.LockExperience(ctx, id(eid)); errors.Is(e, pgx.ErrNoRows) {
			return identity.ErrNotFound
		} else if e != nil {
			return e
		}
		r, e := load(ctx, q, eid)
		if e != nil {
			return e
		}
		if r.CreatorUserID != session.UserID {
			return identity.ErrNotFound
		}
		if r.Version != version {
			return ErrVersion
		}
		changed, e := fn(ctx, tx, q, &r)
		if e != nil {
			return e
		}
		if !changed {
			out = r.Experience
			phase(&out, time.Now())
			return nil
		}
		r.Version++
		out, e = save(ctx, q, r.Experience)
		if e != nil {
			return e
		}
		if e = emit(ctx, q, out, session.UserID, action, requestID); e != nil {
			return e
		}
		phase(&out, time.Now())
		return nil
	})
	return out, err
}
func (s *Service) Update(ctx context.Context, session *identity.Session, eid string, version int64, in Input, requestID string) (Experience, error) {
	in, e := normalized(in)
	if e != nil {
		return Experience{}, e
	}
	return s.mutate(ctx, session, eid, version, "experience.updated", requestID, func(ctx context.Context, tx pgx.Tx, q *dbgen.Queries, r *record) (bool, error) {
		if r.Status != "DRAFT" && r.Status != "PUBLISHED" {
			return false, ErrTransition
		}
		if r.ModerationStatus != "VISIBLE" {
			return false, ErrPublishing
		}
		if r.Status == "PUBLISHED" {
			if !protectedEqual(r.Input, in) {
				return false, ErrProtected
			}
			if r.EndsAt == nil || !r.EndsAt.After(time.Now()) {
				return false, ErrTransition
			}
			candidate := r.Experience
			candidate.Input = in
			if !publishable(candidate, time.Now()) {
				return false, ErrValidation
			}
		} else if e := category(ctx, q, in.CategoryID); e != nil {
			return false, e
		}
		if e := s.media.Bind(ctx, tx, r.ID, session.UserID, in.CoverMediaID); e != nil {
			return false, e
		}
		old, _ := json.Marshal(r.Input)
		next, _ := json.Marshal(in)
		if bytes.Equal(old, next) {
			return false, nil
		}
		r.Input = in
		return true, nil
	})
}
func (s *Service) Transition(ctx context.Context, session *identity.Session, eid string, version int64, target, requestID string) (Experience, error) {
	actions := map[string]string{"PUBLISHED": "experience.published", "CANCELLED": "experience.cancelled", "ARCHIVED": "experience.archived"}
	action, ok := actions[target]
	if !ok {
		return Experience{}, ErrInvalid
	}
	return s.mutate(ctx, session, eid, version, action, requestID, func(ctx context.Context, tx pgx.Tx, q *dbgen.Queries, r *record) (bool, error) {
		if r.Status == target {
			return false, nil
		}
		now := time.Now().UTC()
		switch target {
		case "PUBLISHED":
			if r.Status != "DRAFT" {
				return false, ErrTransition
			}
			if r.ModerationStatus != "VISIBLE" {
				return false, ErrPublishing
			}
			if e := s.publishingAllowed(ctx, q, session.UserID); e != nil {
				return false, e
			}
			if !publishable(r.Experience, now) {
				return false, ErrValidation
			}
			if e := category(ctx, q, r.CategoryID); e != nil {
				return false, e
			}
			if e := s.media.Bind(ctx, tx, r.ID, session.UserID, r.CoverMediaID); e != nil {
				return false, e
			}
			if e := s.quota(ctx, q, session.UserID, "publish", s.config.PublishDaily); e != nil {
				return false, e
			}
			r.PublishedAt = &now
		case "CANCELLED":
			if r.Status != "DRAFT" && (r.Status != "PUBLISHED" || r.EndsAt == nil || !r.EndsAt.After(now)) {
				return false, ErrTransition
			}
			r.CancelledAt = &now
		case "ARCHIVED":
			if r.Status != "DRAFT" && r.Status != "CANCELLED" && (r.Status != "PUBLISHED" || r.EndsAt == nil || r.EndsAt.After(now)) {
				return false, ErrTransition
			}
			r.ArchivedAt = &now
		}
		r.Status = target
		return true, nil
	})
}
func authorized(r record, user string) bool {
	if r.CreatorUserID == user {
		return true
	}
	return r.PublishedAt != nil && r.Visibility != "PRIVATE" && r.ModerationStatus == "VISIBLE"
}
func presentation(r record, user string, now time.Time) Experience {
	e := r.Experience
	phase(&e, now)
	if e.CreatorUserID != user && e.Status != "PUBLISHED" {
		e.DetailsRedacted = true
		e.Description = ""
		e.Location = nil
		e.VenueName = ""
		e.Address = ""
		e.Capacity = nil
		e.ExternalTicketURL = nil
		e.CoverMediaID = nil
	}
	return e
}
func (s *Service) Get(ctx context.Context, session *identity.Session, eid string) (Experience, error) {
	if !id(eid).Valid {
		return Experience{}, ErrInvalid
	}
	r, e := load(ctx, dbgen.New(s.pool), eid)
	if e != nil {
		return Experience{}, e
	}
	if session == nil || !authorized(r, session.UserID) {
		return Experience{}, identity.ErrNotFound
	}
	return presentation(r, session.UserID, time.Now()), nil
}
func (s *Service) Cover(ctx context.Context, session *identity.Session, eid string) ([]byte, string, error) {
	e, err := s.Get(ctx, session, eid)
	if err != nil {
		return nil, "", err
	}
	if e.CoverMediaID == nil {
		return nil, "", identity.ErrNotFound
	}
	return s.media.ReadCover(ctx, *e.CoverMediaID)
}
func (s *Service) Categories(ctx context.Context) ([]Category, error) {
	rows, e := dbgen.New(s.pool).ListExperienceCategories(ctx)
	if e != nil {
		return nil, e
	}
	out := make([]Category, 0, len(rows))
	for _, r := range rows {
		out = append(out, Category{r.ID, r.Name, r.SortOrder})
	}
	return out, nil
}
func (s *Service) Cleanup(ctx context.Context) error {
	return database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		q := dbgen.New(tx)
		if e := q.CleanupExperienceTechnical(ctx); e != nil {
			return e
		}
		if e := q.CleanupExperienceRates(ctx); e != nil {
			return e
		}
		return q.CleanupExperienceAudit(ctx)
	})
}
