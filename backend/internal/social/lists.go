package social

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5/pgtype"
	"strings"
	"time"
)

type cursor struct {
	User, Session, Section, Target, ID string
	Limit                              int
	Snapshot, Time, Expires            time.Time
}

func (s *Service) sign(v any) string {
	b, _ := json.Marshal(v)
	m := hmac.New(sha256.New, s.config.Key)
	m.Write(b)
	return base64.RawURLEncoding.EncodeToString(b) + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
func (s *Service) verify(raw string, v any) bool {
	if len(raw) > 2048 {
		return false
	}
	p := strings.Split(raw, ".")
	if len(p) != 2 {
		return false
	}
	b, e := base64.RawURLEncoding.DecodeString(p[0])
	if e != nil {
		return false
	}
	sig, e := base64.RawURLEncoding.DecodeString(p[1])
	if e != nil {
		return false
	}
	m := hmac.New(sha256.New, s.config.Key)
	m.Write(b)
	return hmac.Equal(sig, m.Sum(nil)) && json.Unmarshal(b, v) == nil
}
func (s *Service) List(ctx context.Context, a *identity.Session, section, target, raw string, limit int) (Page, error) {
	now := time.Now().UTC()
	out := Page{Items: []map[string]any{}, AsOf: now, ValidUntil: now.Add(30 * time.Second)}
	if a == nil {
		return out, identity.ErrUnauthorized
	}
	if limit < 1 || limit > 50 {
		return out, identity.ErrInvalid
	}
	if target != "" && !id(target).Valid {
		return out, identity.ErrInvalid
	}
	c := cursor{a.UserID, a.ID, section, target, "ffffffff-ffff-ffff-ffff-ffffffffffff", limit, now, now.Add(time.Second), now.Add(15 * time.Minute)}
	if raw != "" {
		if !s.verify(raw, &c) || c.User != a.UserID || c.Session != a.ID || c.Section != section || c.Target != target || c.Limit != limit || !c.Expires.After(now) || c.Snapshot.After(now) || !id(c.ID).Valid {
			return out, identity.ErrInvalid
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	q := dbgen.New(s.pool)
	active, e := q.SocialActive(ctx, id(a.UserID))
	if e != nil {
		return out, e
	}
	if !active {
		return out, identity.ErrRestricted
	}
	if target != "" && section != "COMMENTS" {
		if e = connected(ctx, q, a.UserID, target); e != nil {
			return out, e
		}
	}
	var ids []pgtype.UUID
	var times []pgtype.Timestamptz
	var docs [][]byte
	switch section {
	case "DISCOVER", "FOLLOWING", "PROFILE":
		r, e := q.SocialFeed(ctx, dbgen.SocialFeedParams{Viewer: id(a.UserID), Snapshot: ts(c.Snapshot), AfterTime: ts(c.Time), AfterID: id(c.ID), Profile: id(target), Mode: section, PageLimit: int32(limit + 1)})
		if e != nil {
			return out, e
		}
		for _, r := range r {
			ids = append(ids, r.ID)
			times = append(times, r.CreatedAt)
			docs = append(docs, r.Document)
		}
	case "COMMENTS":
		if _, e = loadPost(ctx, q, target, a.UserID); e != nil {
			return out, e
		}
		r, e := q.SocialComments(ctx, dbgen.SocialCommentsParams{Viewer: id(a.UserID), PostID: id(target), Snapshot: ts(c.Snapshot), AfterTime: ts(c.Time), AfterID: id(c.ID), PageLimit: int32(limit + 1)})
		if e != nil {
			return out, e
		}
		for _, r := range r {
			ids = append(ids, r.ID)
			times = append(times, r.CreatedAt)
			docs = append(docs, r.Document)
		}
	case "FOLLOWERS", "PEOPLE_FOLLOWING":
		sec := "FOLLOWERS"
		if section == "PEOPLE_FOLLOWING" {
			sec = "FOLLOWING"
		}
		r, e := q.SocialPeople(ctx, dbgen.SocialPeopleParams{Viewer: id(a.UserID), Profile: id(target), Section: sec, Snapshot: ts(c.Snapshot), AfterTime: ts(c.Time), AfterID: id(c.ID), PageLimit: int32(limit + 1)})
		if e != nil {
			return out, e
		}
		for _, r := range r {
			ids = append(ids, r.ID)
			times = append(times, r.CreatedAt)
			docs = append(docs, r.Document)
		}
	case "EXPERIENCES":
		r, e := q.SocialExperienceOptions(ctx, dbgen.SocialExperienceOptionsParams{Viewer: id(a.UserID), Snapshot: ts(c.Snapshot), AfterTime: ts(c.Time), AfterID: id(c.ID), PageLimit: int32(limit + 1)})
		if e != nil {
			return out, e
		}
		for _, r := range r {
			ids = append(ids, r.ID)
			times = append(times, r.CreatedAt)
			docs = append(docs, r.Document)
		}
	case "BLOCKS":
		r, e := q.SocialBlocks(ctx, dbgen.SocialBlocksParams{Viewer: id(a.UserID), Snapshot: ts(c.Snapshot), AfterTime: ts(c.Time), AfterID: id(c.ID), PageLimit: int32(limit + 1)})
		if e != nil {
			return out, e
		}
		for _, r := range r {
			ids = append(ids, r.ID)
			times = append(times, r.CreatedAt)
			docs = append(docs, r.Document)
		}
	default:
		return out, identity.ErrInvalid
	}
	n := min(limit, len(docs))
	for _, b := range docs[:n] {
		d, e := document(b, nil)
		if e != nil {
			return out, e
		}
		if section == "DISCOVER" || section == "FOLLOWING" || section == "PROFILE" {
			s.decorate(d, a)
		}
		out.Items = append(out.Items, d)
	}
	if len(docs) > limit {
		c.ID = str(ids[n-1])
		c.Time = times[n-1].Time
		next := s.sign(c)
		out.NextCursor = &next
	}
	return out, nil
}
