package experiences

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
)

type DiscoveryFilter struct {
	Search  string
	Spatial RadarFilter
}

func parseDiscovery(raw string, c Config, flows bool) (DiscoveryFilter, string, error) {
	var out DiscoveryFilter
	if len(raw) > 4096 {
		return out, "", ErrInvalid
	}
	q, e := url.ParseQuery(raw)
	if e != nil {
		return out, "", ErrInvalid
	}
	allowed := map[string]bool{"q": !flows, "category_id": true, "phase": !flows, "from": !flows, "until": !flows, "latitude": true, "longitude": true, "radius_m": true, "limit": true, "cursor": true}
	for k, v := range q {
		if !allowed[k] || len(v) != 1 || strings.TrimSpace(v[0]) == "" {
			return out, "", ErrInvalid
		}
	}
	out.Search = strings.TrimSpace(q.Get("q"))
	if !utf8.ValidString(out.Search) || utf8.RuneCountInString(out.Search) > 120 {
		return out, "", ErrInvalid
	}
	cur := q.Get("cursor")
	q.Del("cursor")
	q.Del("q")
	q.Set("bbox", "0,0,1,1")
	q.Set("zoom", "12")
	out.Spatial, e = parseRadarQuery(q.Encode())
	if e != nil {
		return out, "", e
	}
	policy := c
	policy.RadarLimit = 50
	if out.Spatial.Limit == 0 {
		out.Spatial.Limit = 20
		if flows {
			out.Spatial.Limit = 12
		}
	}
	e = out.Spatial.validate(policy)
	return out, cur, e
}
func (s *Service) discoveryCursor(session *identity.Session, f DiscoveryFilter, raw, mode string) (cursor, error) {
	data, _ := json.Marshal(struct {
		User, Mode string
		Filter     DiscoveryFilter
		Window     int
	}{session.UserID, mode, f, s.config.FlowsWindowHours})
	hash := sha256.Sum256(data)
	c, e := s.parseCursor(raw, hex.EncodeToString(hash[:]), false)
	if c.Snapshot.IsZero() {
		c.Snapshot = time.Now().UTC()
	}
	return c, e
}

type ExplorePage struct {
	Page
	AsOf       time.Time `json:"as_of"`
	ValidUntil time.Time `json:"valid_until"`
}

func (s *Service) Explore(ctx context.Context, session *identity.Session, f DiscoveryFilter, raw string) (ExplorePage, error) {
	now := time.Now().UTC()
	out := ExplorePage{Page: Page{Items: []Experience{}}, AsOf: now, ValidUntil: now.Add(time.Minute)}
	if session == nil {
		return out, identity.ErrUnauthorized
	}
	c, e := s.discoveryCursor(session, f, raw, "explore.v1")
	if e != nil {
		return out, e
	}
	from, until := now, now
	if f.Spatial.From != nil {
		from, until = *f.Spatial.From, *f.Spatial.Until
	}
	center := Location{}
	if f.Spatial.Center != nil {
		center = *f.Spatial.Center
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	rows, e := dbgen.New(s.pool).ExploreExperiences(ctx, dbgen.ExploreExperiencesParams{Viewer: id(session.UserID), AsOf: ts(now), Search: f.Search, CategoryFilter: f.Spatial.Category, PhaseFilter: f.Spatial.Phase, Period: f.Spatial.From != nil, FromTime: ts(from), UntilTime: ts(until), Nearby: f.Spatial.Center != nil, Longitude: center.Longitude, Latitude: center.Latitude, RadiusM: f.Spatial.RadiusM, AfterTime: ts(c.Time), AfterID: id(c.ID), PageLimit: int32(f.Spatial.Limit + 1)})
	if e != nil {
		return out, e
	}
	more := len(rows) > f.Spatial.Limit
	if more {
		rows = rows[:f.Spatial.Limit]
	}
	for _, raw := range rows {
		r, e := decodeRecord(raw)
		if e != nil {
			return out, e
		}
		out.Items = append(out.Items, presentation(r, session.UserID, now))
		boundFreshness(&out.ValidUntil, r.Experience, now)
	}
	if more {
		last := out.Items[len(out.Items)-1]
		c.ID = last.ID
		c.Time = *last.StartsAt
		next := s.signCursor(c)
		out.NextCursor = &next
	}
	return out, nil
}
func boundFreshness(until *time.Time, e Experience, now time.Time) {
	for _, v := range []*time.Time{e.StartsAt, e.EndsAt} {
		if v != nil && v.After(now) && v.Before(*until) {
			*until = *v
		}
	}
}
