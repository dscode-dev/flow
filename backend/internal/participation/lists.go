package participation

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

type continuation struct {
	Scope, ID     string
	Time, Expires time.Time
}

func (s *Service) cursor(raw, scope string) (continuation, error) {
	c := continuation{scope, "00000000-0000-0000-0000-000000000000", time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC), time.Now().Add(15 * time.Minute)}
	if raw == "" {
		return c, nil
	}
	if len(raw) > 2048 {
		return c, ErrInvalid
	}
	p := strings.Split(raw, ".")
	if len(p) != 2 {
		return c, ErrInvalid
	}
	b, e := base64.RawURLEncoding.DecodeString(p[0])
	if e != nil {
		return c, ErrInvalid
	}
	sig, e := base64.RawURLEncoding.DecodeString(p[1])
	if e != nil {
		return c, ErrInvalid
	}
	m := hmac.New(sha256.New, s.config.Key)
	m.Write([]byte("cursor:"))
	m.Write(b)
	if !hmac.Equal(sig, m.Sum(nil)) || json.Unmarshal(b, &c) != nil || c.Scope != scope || !id(c.ID).Valid || !c.Expires.After(time.Now()) {
		return c, ErrInvalid
	}
	return c, nil
}
func (s *Service) next(c continuation) string {
	b, _ := json.Marshal(c)
	m := hmac.New(sha256.New, s.config.Key)
	m.Write([]byte("cursor:"))
	m.Write(b)
	return base64.RawURLEncoding.EncodeToString(b) + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
func (s *Service) page(rows [][]byte, limit int, c continuation, idField string, now time.Time) (Page, error) {
	out := Page{Items: []map[string]any{}, AsOf: now, ValidUntil: now.Add(time.Minute)}
	more := len(rows) > limit
	if more {
		rows = rows[:limit]
	}
	for _, r := range rows {
		var v map[string]any
		if err := json.Unmarshal(r, &v); err != nil {
			return out, err
		}
		out.Items = append(out.Items, v)
	}
	if more {
		last := out.Items[len(out.Items)-1]
		c.ID = last[idField].(string)
		if v, ok := last["sort_time"].(string); ok {
			var err error
			c.Time, err = time.Parse(time.RFC3339Nano, v)
			if err != nil {
				return out, err
			}
		}
		v := s.next(c)
		out.NextCursor = &v
	}
	// sort_time is only a pagination implementation detail, never public state.
	for _, v := range out.Items {
		delete(v, "sort_time")
	}
	return out, nil
}
func (s *Service) Roster(ctx context.Context, a *identity.Session, eid, kind, filter, raw string, limit int) (json.RawMessage, error) {
	if limit < 1 || limit > 50 || kind != "participants" && kind != "invitations" {
		return nil, ErrInvalid
	}
	if filter != "" && filter != "NONE" && filter != "PENDING" && filter != "CONFIRMED" && filter != "DECLINED" && filter != "CANCELLED" && filter != "REMOVED" {
		return nil, ErrInvalid
	}
	if kind == "invitations" && filter != "" {
		return nil, ErrInvalid
	}
	if a == nil {
		return nil, identity.ErrUnauthorized
	}
	scopeBytes, _ := json.Marshal([]any{a.UserID, eid, kind, filter, limit})
	scope := string(scopeBytes)
	c, err := s.cursor(raw, scope)
	if err != nil {
		return nil, err
	}
	return s.run(ctx, a, eid, "", "list", "", nil, false, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, current state) (any, error) {
		if !current.owner(a.UserID) {
			return nil, identity.ErrNotFound
		}
		var rows [][]byte
		var err error
		field := "user_id"
		if kind == "participants" {
			rows, err = q.ListParticipationMembers(ctx, dbgen.ListParticipationMembersParams{ExperienceID: id(eid), StateFilter: filter, AfterID: id(c.ID), PageLimit: int32(limit + 1)})
		} else {
			field = "id"
			rows, err = q.ListParticipationInvitations(ctx, dbgen.ListParticipationInvitationsParams{ExperienceID: id(eid), AfterID: id(c.ID), PageLimit: int32(limit + 1)})
		}
		if err != nil {
			return nil, err
		}
		return s.page(rows, limit, c, field, current.now)
	})
}
func (s *Service) Agenda(ctx context.Context, a *identity.Session, section, raw string, limit int) (Page, error) {
	out := Page{Items: []map[string]any{}}
	if a == nil {
		return out, identity.ErrUnauthorized
	}
	if limit < 1 || limit > 50 {
		return out, ErrInvalid
	}
	switch section {
	case "upcoming", "interests", "pending", "invitations", "history":
	default:
		return out, ErrInvalid
	}
	scopeBytes, _ := json.Marshal([]any{a.UserID, "agenda", section, limit})
	c, err := s.cursor(raw, string(scopeBytes))
	if err != nil {
		return out, err
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	err = database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if err := identity.RequireCreator(ctx, tx, a); err != nil {
			return err
		}
		rows, err := dbgen.New(tx).ListParticipationAgenda(ctx, dbgen.ListParticipationAgendaParams{Viewer: id(a.UserID), Section: section, AfterTime: ts(c.Time), AfterID: id(c.ID), PageLimit: int32(limit + 1)})
		if err != nil {
			return err
		}
		out, err = s.page(rows, limit, c, "experience_id", time.Now().UTC())
		return err
	})
	return out, err
}
