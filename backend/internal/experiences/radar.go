package experiences

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/platform/database/dbgen"
	"flow.local/backend/internal/platform/httpapi"
)

var ErrRadarArea = &identity.Failure{Code: "radar_area_too_large", Status: 400}

type RadarFilter struct {
	West, South, East, North, Zoom float64
	Category, Phase                string
	From, Until                    *time.Time
	Center                         *Location
	RadiusM                        float64
	Limit                          int
}
type RadarMarker struct {
	ID             string    `json:"id"`
	Title          string    `json:"title"`
	CategoryID     string    `json:"category_id"`
	CategoryName   string    `json:"category_name"`
	Location       Location  `json:"location"`
	StartsAt       time.Time `json:"starts_at"`
	EndsAt         time.Time `json:"ends_at"`
	Timezone       string    `json:"timezone"`
	VenueName      string    `json:"venue_name"`
	CoverMediaID   *string   `json:"cover_media_id"`
	Version        int64     `json:"version"`
	Phase          string    `json:"phase"`
	ExternalTicket bool      `json:"external_ticket"`
}
type RadarPage struct {
	AsOf           time.Time     `json:"as_of"`
	ValidUntil     time.Time     `json:"valid_until"`
	Items          []RadarMarker `json:"items"`
	Truncated      bool          `json:"truncated"`
	Limit          int           `json:"limit"`
	MinZoom        int           `json:"min_zoom"`
	MaxSpanDegrees int           `json:"max_span_degrees"`
}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }
func (f *RadarFilter) validate(c Config) error {
	for _, v := range []float64{f.West, f.South, f.East, f.North, f.Zoom, f.RadiusM} {
		if !finite(v) {
			return ErrInvalid
		}
	}
	if f.West < -180 || f.West > 180 || f.East < -180 || f.East > 180 || f.South < -85.051129 || f.North > 85.051129 || f.North <= f.South || f.Zoom < 0 || f.Zoom > 22 {
		return ErrInvalid
	}
	width := f.East - f.West
	if width < 0 {
		width += 360
	}
	if width == 0 {
		return ErrInvalid
	}
	if f.Zoom < float64(c.RadarMinZoom) || width > float64(c.RadarMaxSpan) || f.North-f.South > float64(c.RadarMaxSpan) {
		return ErrRadarArea
	}
	if f.Limit == 0 {
		f.Limit = c.RadarLimit
	}
	if f.Limit < 1 || f.Limit > c.RadarLimit || len(f.Category) > 40 || (f.Phase != "" && f.Phase != "LIVE" && f.Phase != "UPCOMING") {
		return ErrInvalid
	}
	if (f.From == nil) != (f.Until == nil) {
		return ErrInvalid
	}
	if f.From != nil {
		for _, v := range []*time.Time{f.From, f.Until} {
			_, off := v.Zone()
			if off != 0 || v.Year() < 2000 || v.Year() > 2200 {
				return ErrInvalid
			}
		}
		if !f.Until.After(*f.From) || f.Until.Sub(*f.From) > 31*24*time.Hour {
			return ErrInvalid
		}
	}
	if f.Center != nil {
		if _, e := normalized(Input{Location: f.Center}); e != nil || f.RadiusM < 1000 || f.RadiusM > 100000 {
			return ErrInvalid
		}
		f.Center = &Location{math.Round(f.Center.Latitude*100) / 100, math.Round(f.Center.Longitude*100) / 100}
	} else if f.RadiusM != 0 {
		return ErrInvalid
	}
	return nil
}
func (s *Service) Radar(ctx context.Context, session *identity.Session, f RadarFilter) (RadarPage, error) {
	now := time.Now().UTC()
	out := RadarPage{AsOf: now, ValidUntil: now.Add(time.Minute), Items: []RadarMarker{}, MinZoom: s.config.RadarMinZoom, MaxSpanDegrees: s.config.RadarMaxSpan}
	if session == nil {
		return out, identity.ErrUnauthorized
	}
	if err := f.validate(s.config); err != nil {
		return out, err
	}
	out.Limit = f.Limit
	from, until := now, now
	if f.From != nil {
		from, until = *f.From, *f.Until
	}
	center := Location{}
	if f.Center != nil {
		center = *f.Center
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	raw, err := dbgen.New(s.pool).RadarExperiences(ctx, dbgen.RadarExperiencesParams{
		AsOf: ts(now), West: f.West, South: f.South, East: f.East, North: f.North, Crosses: f.West > f.East,
		CategoryFilter: f.Category, PhaseFilter: f.Phase, Period: f.From != nil, FromTime: ts(from), UntilTime: ts(until),
		Nearby: f.Center != nil, Latitude: center.Latitude, Longitude: center.Longitude, RadiusM: f.RadiusM, ResultLimit: int32(f.Limit + 1),
	})
	if err != nil {
		return out, err
	}
	out.Truncated = len(raw) > f.Limit
	if out.Truncated {
		raw = raw[:f.Limit]
	}
	for _, r := range raw {
		var m RadarMarker
		if e := json.Unmarshal(r, &m); e != nil {
			return out, e
		}
		out.Items = append(out.Items, m)
		for _, v := range []time.Time{m.StartsAt, m.EndsAt} {
			if v.After(now) && v.Before(out.ValidUntil) {
				out.ValidUntil = v
			}
		}
	}
	return out, nil
}
func parseRadarQuery(raw string) (RadarFilter, error) {
	f := RadarFilter{}
	if len(raw) > 2048 {
		return f, ErrInvalid
	}
	q, err := url.ParseQuery(raw)
	if err != nil {
		return f, ErrInvalid
	}
	allowed := map[string]bool{"bbox": true, "zoom": true, "category_id": true, "phase": true, "from": true, "until": true, "latitude": true, "longitude": true, "radius_m": true, "limit": true}
	for k, v := range q {
		if !allowed[k] || len(v) != 1 || strings.TrimSpace(v[0]) == "" {
			return f, ErrInvalid
		}
	}
	bounds := strings.Split(q.Get("bbox"), ",")
	if len(bounds) != 4 {
		return f, ErrInvalid
	}
	for i, p := range []*float64{&f.West, &f.South, &f.East, &f.North} {
		*p, err = strconv.ParseFloat(bounds[i], 64)
		if err != nil {
			return f, ErrInvalid
		}
	}
	f.Zoom, err = strconv.ParseFloat(q.Get("zoom"), 64)
	if err != nil {
		return f, ErrInvalid
	}
	f.Category, f.Phase = q.Get("category_id"), q.Get("phase")
	if q.Has("limit") {
		f.Limit, err = strconv.Atoi(q.Get("limit"))
		if err != nil || f.Limit < 1 {
			return f, ErrInvalid
		}
	}
	if q.Has("from") || q.Has("until") {
		a, e1 := time.Parse(time.RFC3339Nano, q.Get("from"))
		b, e2 := time.Parse(time.RFC3339Nano, q.Get("until"))
		if e1 != nil || e2 != nil {
			return f, ErrInvalid
		}
		f.From, f.Until = &a, &b
	}
	if q.Has("latitude") || q.Has("longitude") || q.Has("radius_m") {
		a, e1 := strconv.ParseFloat(q.Get("latitude"), 64)
		b, e2 := strconv.ParseFloat(q.Get("longitude"), 64)
		r, e3 := strconv.ParseFloat(q.Get("radius_m"), 64)
		if e1 != nil || e2 != nil || e3 != nil {
			return f, ErrInvalid
		}
		f.Center = &Location{a, b}
		f.RadiusM = r
	}
	return f, nil
}
func (h *Handler) radar(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	f, err := parseRadarQuery(r.URL.RawQuery)
	if err != nil {
		failure(w, r, err)
		return
	}
	out, err := h.service.Radar(r.Context(), identityhttp.Session(r), f)
	if err != nil {
		failure(w, r, err)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil || len(raw) > 1024*1024 {
		failure(w, r, identity.ErrStorage)
		return
	}
	h.log.InfoContext(r.Context(), "radar query", "request_id", httpapi.RequestID(r.Context()), "duration_ms", time.Since(start).Milliseconds(), "returned", len(out.Items), "truncated", out.Truncated)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(200)
	_, _ = w.Write(raw)
}
