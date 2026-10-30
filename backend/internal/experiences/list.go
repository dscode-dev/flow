package experiences

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
)

type Filter struct {
	Status    string  `json:"status"`
	Category  string  `json:"category"`
	Phase     string  `json:"phase"`
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	RadiusM   float64 `json:"radius_m"`
	Nearby    bool    `json:"nearby"`
	Limit     int32   `json:"limit"`
}
type cursor struct {
	Scope   string    `json:"scope"`
	Time    time.Time `json:"time"`
	ID      string    `json:"id"`
	Expires time.Time `json:"expires"`
}

func (s *Service) signCursor(c cursor) string {
	raw, _ := json.Marshal(c)
	mac := hmac.New(sha256.New, s.config.CursorKey)
	mac.Write(raw)
	return base64.RawURLEncoding.EncodeToString(raw) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
func (s *Service) parseCursor(raw, scope string, own bool) (cursor, error) {
	now := time.Now().UTC()
	c := cursor{Scope: scope, Time: time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC), ID: "00000000-0000-0000-0000-000000000000", Expires: now.Add(15 * time.Minute)}
	if own {
		c.Time = now.Add(time.Microsecond)
		c.ID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
	}
	if raw == "" {
		return c, nil
	}
	if len(raw) > 2048 {
		return c, ErrInvalid
	}
	parts := strings.Split(raw, ".")
	if len(parts) != 2 {
		return c, ErrInvalid
	}
	b, e := base64.RawURLEncoding.DecodeString(parts[0])
	if e != nil {
		return c, ErrInvalid
	}
	sig, e := base64.RawURLEncoding.DecodeString(parts[1])
	if e != nil {
		return c, ErrInvalid
	}
	mac := hmac.New(sha256.New, s.config.CursorKey)
	mac.Write(b)
	if !hmac.Equal(sig, mac.Sum(nil)) || json.Unmarshal(b, &c) != nil || c.Scope != scope || !id(c.ID).Valid || !c.Expires.After(now) {
		return c, ErrInvalid
	}
	return c, nil
}
func (s *Service) List(ctx context.Context, session *identity.Session, own bool, f Filter, rawCursor string) (Page, error) {
	out := Page{Items: []Experience{}}
	if session == nil {
		return out, identity.ErrUnauthorized
	}
	if f.Limit < 1 || f.Limit > 100 {
		return out, ErrInvalid
	}
	if own {
		if f.Category != "" || f.Phase != "" || f.Nearby {
			return out, ErrInvalid
		}
		if f.Status != "" && f.Status != "DRAFT" && f.Status != "PUBLISHED" && f.Status != "CANCELLED" && f.Status != "ARCHIVED" {
			return out, ErrInvalid
		}
	} else {
		if f.Status != "" || len(f.Category) > 40 || (f.Phase != "" && f.Phase != "UPCOMING" && f.Phase != "LIVE") {
			return out, ErrInvalid
		}
		if f.Nearby {
			if math.IsNaN(f.RadiusM) || math.IsInf(f.RadiusM, 0) {
				return out, ErrInvalid
			}
			if _, e := normalized(Input{Location: &Location{f.Latitude, f.Longitude}}); e != nil || f.RadiusM < 100 || f.RadiusM > 100000 {
				return out, ErrInvalid
			}
		}
	}
	scopeData, _ := json.Marshal(struct {
		Owner  string
		Own    bool
		Filter Filter
	}{session.UserID, own, f})
	hash := sha256.Sum256(scopeData)
	scope := hex.EncodeToString(hash[:])
	c, e := s.parseCursor(rawCursor, scope, own)
	if e != nil {
		return out, e
	}
	q := dbgen.New(s.pool)
	now := time.Now().UTC()
	var rows [][]byte
	if own {
		rows, e = q.ListOwnExperiences(ctx, dbgen.ListOwnExperiencesParams{Owner: id(session.UserID), StatusFilter: f.Status, BeforeTime: ts(c.Time), BeforeID: id(c.ID), PageLimit: f.Limit + 1})
	} else {
		rows, e = q.DiscoverExperiences(ctx, dbgen.DiscoverExperiencesParams{AsOf: ts(now), CategoryFilter: f.Category, PhaseFilter: f.Phase, AfterTime: ts(c.Time), AfterID: id(c.ID), Nearby: f.Nearby, Latitude: f.Latitude, Longitude: f.Longitude, RadiusM: f.RadiusM, PageLimit: f.Limit + 1})
	}
	if e != nil {
		return out, e
	}
	hasMore := len(rows) > int(f.Limit)
	if hasMore {
		rows = rows[:f.Limit]
	}
	for _, raw := range rows {
		r, e := decodeRecord(raw)
		if e != nil {
			return out, e
		}
		out.Items = append(out.Items, presentation(r, session.UserID, now))
	}
	if hasMore {
		last := out.Items[len(out.Items)-1]
		c.ID = last.ID
		c.Time = last.CreatedAt
		if !own {
			c.Time = *last.StartsAt
		}
		next := s.signCursor(c)
		out.NextCursor = &next
	}
	return out, nil
}
