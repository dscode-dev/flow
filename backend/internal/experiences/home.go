package experiences

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"time"

	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/platform/database/dbgen"
)

type HomeFilter struct {
	Location       *Location
	RadiusM, Limit int
	Category       string
}
type HomeItem struct {
	Experience   Experience `json:"experience"`
	CategoryName string     `json:"category_name"`
	DistanceM    *int       `json:"distance_m"`
}
type HomeSection struct {
	ID           string     `json:"id"`
	Order        string     `json:"order"`
	Availability string     `json:"availability"`
	Items        []HomeItem `json:"items"`
}
type HomeLocality struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	RadiusM   int     `json:"radius_m"`
}
type Home struct {
	AsOf           time.Time     `json:"as_of"`
	RefreshAt      time.Time     `json:"refresh_at"`
	SoonHours      int           `json:"soon_hours"`
	DefaultRadiusM int           `json:"default_radius_m"`
	SectionLimit   int           `json:"section_limit"`
	Locality       *HomeLocality `json:"locality"`
	CategoryID     *string       `json:"category_id"`
	Categories     []Category    `json:"categories"`
	Sections       []HomeSection `json:"sections"`
}

// Home is a bounded, uncached composition of the authoritative discovery view.
// There is no editorial/popularity score or implicit individual preference.
func (s *Service) Home(ctx context.Context, session *identity.Session, f HomeFilter) (Home, error) {
	now := time.Now().UTC()
	out := Home{AsOf: now, RefreshAt: now.Add(time.Minute), SoonHours: s.config.HomeSoonHours, DefaultRadiusM: s.config.HomeRadiusM, Sections: []HomeSection{}}
	if session == nil {
		return out, identity.ErrUnauthorized
	}
	if f.Limit == 0 {
		f.Limit = s.config.HomeLimit
	}
	if f.RadiusM == 0 {
		f.RadiusM = s.config.HomeRadiusM
	}
	if f.Limit < 1 || f.Limit > s.config.HomeLimit || f.RadiusM < 1000 || f.RadiusM > 100000 || len(f.Category) > 40 || (f.Location == nil && f.RadiusM != s.config.HomeRadiusM) {
		return out, ErrInvalid
	}
	out.SectionLimit = f.Limit
	lat, lng := 0.0, 0.0
	if f.Location != nil {
		if _, err := normalized(Input{Location: f.Location}); err != nil {
			return out, ErrInvalid
		}
		// A selected region centre, never a precise device position or stored trail.
		lat = math.Round(f.Location.Latitude*100) / 100
		lng = math.Round(f.Location.Longitude*100) / 100
		out.Locality = &HomeLocality{lat, lng, f.RadiusM}
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	categoryRows, err := dbgen.New(s.pool).HomeCategories(ctx)
	if err != nil {
		return out, err
	}
	categories := make([]Category, 0, len(categoryRows))
	for _, c := range categoryRows {
		categories = append(categories, Category{ID: c.ID, Name: c.Name, SortOrder: c.SortOrder})
	}
	out.Categories = categories
	if f.Category != "" {
		found := false
		for _, c := range categories {
			if c.ID == f.Category {
				found = true
			}
		}
		if !found {
			return out, ErrInvalid
		}
		out.CategoryID = &f.Category
	}
	rows, err := dbgen.New(s.pool).HomeCandidates(ctx, dbgen.HomeCandidatesParams{Viewer: id(session.UserID),
		AsOf: ts(now), SoonUntil: ts(now.Add(time.Duration(s.config.HomeSoonHours) * time.Hour)),
		SectionLimit: int32(f.Limit), Nearby: f.Location != nil, Latitude: lat, Longitude: lng, RadiusM: float64(f.RadiusM), CategoryFilter: f.Category,
	})
	if err != nil {
		return out, err
	}
	// SQL branch order is not a contractual ordering. Sort explicitly with ID ties.
	sort.Slice(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.CSection != b.CSection {
			return a.CSection < b.CSection
		}
		if a.CSection == "nearby" && a.CDistanceM != b.CDistanceM {
			return a.CDistanceM < b.CDistanceM
		}
		if a.CSection == "recent" && !a.CreatedAt.Time.Equal(b.CreatedAt.Time) {
			return a.CreatedAt.Time.After(b.CreatedAt.Time)
		}
		if a.CSection != "recent" && !a.StartsAt.Time.Equal(b.StartsAt.Time) {
			if a.CSection == "live" {
				return a.StartsAt.Time.After(b.StartsAt.Time)
			}
			return a.StartsAt.Time.Before(b.StartsAt.Time)
		}
		if a.CSection == "contextual" && !a.CreatedAt.Time.Equal(b.CreatedAt.Time) {
			return a.CreatedAt.Time.After(b.CreatedAt.Time)
		}
		if a.CSection == "live" || a.CSection == "recent" {
			return a.ID.String() > b.ID.String()
		}
		return a.ID.String() < b.ID.String()
	})
	occurrences := map[string]int{}
	for _, spec := range []struct{ id, order string }{{"highlights", "starts_at_asc_id_asc"}, {"live", "starts_at_desc_id_desc"}, {"soon", "starts_at_asc_id_asc"}, {"nearby", "distance_asc_starts_at_asc_id_asc"}, {"contextual", "starts_at_asc_created_at_desc_id_asc"}, {"recent", "created_at_desc_id_desc"}} {
		section := HomeSection{ID: spec.id, Order: spec.order, Availability: "empty", Items: []HomeItem{}}
		if spec.id == "nearby" && f.Location == nil {
			section.Availability = "locality_required"
		}
		for _, row := range rows {
			if row.CSection != spec.id {
				continue
			}
			rec, decodeErr := decodeRecord(row.CDocument)
			if decodeErr != nil {
				return out, decodeErr
			}
			e := presentation(rec, session.UserID, now)
			if occurrences[e.ID] >= 2 {
				continue
			}
			occurrences[e.ID]++
			item := HomeItem{Experience: e, CategoryName: row.CategoryName}
			if spec.id == "nearby" {
				distance := int(math.Round(row.CDistanceM/100) * 100)
				item.DistanceM = &distance
			}
			section.Items = append(section.Items, item)
			section.Availability = "available"
			for _, boundary := range []*time.Time{e.StartsAt, e.EndsAt} {
				if boundary != nil && boundary.After(now) && boundary.Before(out.RefreshAt) {
					out.RefreshAt = *boundary
				}
			}
		}
		out.Sections = append(out.Sections, section)
	}
	return out, nil
}

func (h *Handler) home(w http.ResponseWriter, r *http.Request) {
	if len(r.URL.RawQuery) > 2048 {
		failure(w, r, ErrInvalid)
		return
	}
	q, parseErr := url.ParseQuery(r.URL.RawQuery)
	if parseErr != nil {
		failure(w, r, ErrInvalid)
		return
	}
	allowed := map[string]bool{"latitude": true, "longitude": true, "radius_m": true, "limit": true, "category_id": true}
	for key, values := range q {
		if !allowed[key] || len(values) != 1 || values[0] == "" {
			failure(w, r, ErrInvalid)
			return
		}
	}
	f := HomeFilter{Category: q.Get("category_id")}
	for _, p := range []struct {
		k string
		v *int
	}{{"radius_m", &f.RadiusM}, {"limit", &f.Limit}} {
		if q.Has(p.k) {
			n, e := strconv.Atoi(q.Get(p.k))
			if e != nil || n <= 0 {
				failure(w, r, ErrInvalid)
				return
			}
			*p.v = n
		}
	}
	if q.Has("latitude") || q.Has("longitude") || q.Has("radius_m") {
		lat, e1 := strconv.ParseFloat(q.Get("latitude"), 64)
		lng, e2 := strconv.ParseFloat(q.Get("longitude"), 64)
		if e1 != nil || e2 != nil {
			failure(w, r, ErrInvalid)
			return
		}
		f.Location = &Location{lat, lng}
	}
	out, err := h.service.Home(r.Context(), identityhttp.Session(r), f)
	if err != nil {
		failure(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	// Bound serialized output too, including Unicode/escaping and catalog growth.
	raw, encodeErr := json.Marshal(out)
	if encodeErr != nil || len(raw) > 2*1024*1024 {
		failure(w, r, identity.ErrStorage)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(200)
	_, _ = w.Write(raw)
}
