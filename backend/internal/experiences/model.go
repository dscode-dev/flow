// Package experiences owns authored experiences, not attendance or ticketing.
package experiences

import (
	"bytes"
	"encoding/json"
	"math"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"
	"unicode"
	"unicode/utf8"

	"flow.local/backend/internal/identity"
	"github.com/google/uuid"
	"golang.org/x/text/unicode/norm"
)

var (
	ErrInvalid      = &identity.Failure{Code: "invalid_request", Status: 400}
	ErrValidation   = &identity.Failure{Code: "experience_invalid", Status: 422}
	ErrTransition   = &identity.Failure{Code: "invalid_transition", Status: 409}
	ErrProtected    = &identity.Failure{Code: "protected_attributes", Status: 409}
	ErrVersion      = &identity.Failure{Code: "version_conflict", Status: 412}
	ErrPrecondition = &identity.Failure{Code: "precondition_required", Status: 428}
	ErrIdempotency  = &identity.Failure{Code: "idempotency_conflict", Status: 409}
	ErrDraftLimit   = &identity.Failure{Code: "draft_limit", Status: 409}
	ErrPublishing   = &identity.Failure{Code: "publishing_restricted", Status: 403}
)

type Location struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

func (l *Location) UnmarshalJSON(raw []byte) error {
	var value struct {
		Latitude  *float64 `json:"latitude"`
		Longitude *float64 `json:"longitude"`
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&value) != nil || value.Latitude == nil || value.Longitude == nil {
		return ErrInvalid
	}
	l.Latitude, l.Longitude = *value.Latitude, *value.Longitude
	return nil
}

// Input is the complete editable document. PUT replaces it; null clears optional
// values. Lifecycle, owner, moderation, timestamps and version are server-owned.
type Input struct {
	Title             string     `json:"title"`
	Description       string     `json:"description"`
	CategoryID        *string    `json:"category_id"`
	Visibility        string     `json:"visibility,omitempty"`
	StartsAt          *time.Time `json:"starts_at"`
	EndsAt            *time.Time `json:"ends_at"`
	Timezone          *string    `json:"timezone"`
	Location          *Location  `json:"location"`
	VenueName         string     `json:"venue_name"`
	Address           string     `json:"address"`
	Capacity          *int32     `json:"capacity"`
	ExternalTicketURL *string    `json:"external_ticket_url"`
	CoverMediaID      *string    `json:"cover_media_id"`
}
type Experience struct {
	Input
	ID              string     `json:"id"`
	CreatorUserID   string     `json:"creator_user_id"`
	LocationType    string     `json:"location_type"`
	Status          string     `json:"status"`
	Phase           *string    `json:"phase"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
	PublishedAt     *time.Time `json:"published_at"`
	CancelledAt     *time.Time `json:"cancelled_at"`
	ArchivedAt      *time.Time `json:"archived_at"`
	Version         int64      `json:"version"`
	DetailsRedacted bool       `json:"details_redacted"`
}
type record struct {
	Experience
	ModerationStatus string `json:"moderation_status"`
}
type Page struct {
	Items      []Experience `json:"items"`
	NextCursor *string      `json:"next_cursor"`
}
type Category struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	SortOrder int32  `json:"sort_order"`
}

func clean(s string, max int, multiline bool) (string, error) {
	if !utf8.ValidString(s) {
		return "", ErrValidation
	}
	s = norm.NFC.String(strings.TrimSpace(strings.ReplaceAll(s, "\r\n", "\n")))
	if utf8.RuneCountInString(s) > max {
		return "", ErrValidation
	}
	for _, r := range s {
		if (unicode.IsControl(r) && !(multiline && (r == '\n' || r == '\t'))) || unicode.Is(unicode.Cf, r) {
			return "", ErrValidation
		}
	}
	return s, nil
}
func normalized(in Input) (Input, error) {
	var err error
	for _, p := range []struct {
		v     *string
		max   int
		multi bool
	}{{&in.Title, 120, false}, {&in.Description, 5000, true}, {&in.VenueName, 160, false}, {&in.Address, 300, false}} {
		*p.v, err = clean(*p.v, p.max, p.multi)
		if err != nil {
			return in, err
		}
	}
	if in.Visibility == "" {
		in.Visibility = "PRIVATE"
	}
	if in.Visibility != "PRIVATE" && in.Visibility != "UNLISTED" && in.Visibility != "PUBLIC" {
		return in, ErrValidation
	}
	if in.CategoryID != nil {
		v := strings.TrimSpace(*in.CategoryID)
		if v == "" || len(v) > 40 {
			return in, ErrValidation
		}
		in.CategoryID = &v
	}
	if in.Timezone != nil {
		v := strings.TrimSpace(*in.Timezone)
		if len(v) > 100 || v == "Local" || v == "" || (!strings.Contains(v, "/") && v != "UTC") {
			return in, ErrValidation
		}
		if _, err = time.LoadLocation(v); err != nil {
			return in, ErrValidation
		}
		in.Timezone = &v
	}
	// RFC3339 instants must be explicit UTC. Clients resolve civil/DST ambiguity
	// themselves using the selected IANA zone; the server never guesses an offset.
	for _, t := range []*time.Time{in.StartsAt, in.EndsAt} {
		if t != nil {
			_, off := t.Zone()
			if off != 0 || t.Year() < 2000 || t.Year() > 2200 {
				return in, ErrValidation
			}
			*t = t.UTC().Truncate(time.Microsecond)
		}
	}
	if in.StartsAt != nil && in.EndsAt != nil && (!in.EndsAt.After(*in.StartsAt) || in.EndsAt.Sub(*in.StartsAt) > 31*24*time.Hour) {
		return in, ErrValidation
	}
	if in.Location != nil {
		a, b := in.Location.Latitude, in.Location.Longitude
		if math.IsNaN(a) || math.IsInf(a, 0) || math.IsNaN(b) || math.IsInf(b, 0) || a < -90 || a > 90 || b < -180 || b > 180 {
			return in, ErrValidation
		}
		in.Location = &Location{math.Round(a*1e6) / 1e6, math.Round(b*1e6) / 1e6}
	}
	if in.Capacity != nil && (*in.Capacity < 1 || *in.Capacity > 1000000) {
		return in, ErrValidation
	}
	if in.CoverMediaID != nil {
		u, e := uuid.Parse(*in.CoverMediaID)
		if e != nil {
			return in, ErrValidation
		}
		v := u.String()
		in.CoverMediaID = &v
	}
	if in.ExternalTicketURL != nil {
		v := strings.TrimSpace(*in.ExternalTicketURL)
		if !safeTicket(v) {
			return in, ErrValidation
		}
		in.ExternalTicketURL = &v
	}
	return in, nil
}
func safeTicket(raw string) bool {
	if len(raw) > 2048 || strings.ContainsAny(raw, "\\\r\n\t ") {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.Opaque != "" || u.User != nil || u.Fragment != "" {
		return false
	}
	h := strings.ToLower(u.Hostname())
	if h == "localhost" || strings.HasSuffix(h, ".localhost") || !strings.Contains(h, ".") || net.ParseIP(h) != nil || strings.HasSuffix(h, ".") {
		return false
	}
	if p := u.Port(); p != "" && p != "443" {
		return false
	}
	for _, part := range strings.Split(h, ".") {
		if len(part) == 0 || len(part) > 63 || part[0] == '-' || part[len(part)-1] == '-' {
			return false
		}
		for _, r := range part {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				return false
			}
		}
	}
	return true // No DNS resolution, preview, redirect or server-side fetch.
}
func publishable(e Experience, now time.Time) bool {
	return utf8.RuneCountInString(e.Title) >= 3 && utf8.RuneCountInString(e.Description) >= 10 && e.CategoryID != nil && e.StartsAt != nil && e.EndsAt != nil && e.Timezone != nil && e.Location != nil && utf8.RuneCountInString(e.VenueName) >= 2 && e.EndsAt.After(now) && e.StartsAt.Before(now.Add(366*24*time.Hour))
}
func phase(e *Experience, now time.Time) {
	e.Phase = nil
	if e.Status != "PUBLISHED" || e.StartsAt == nil || e.EndsAt == nil {
		return
	}
	p := "UPCOMING"
	if !now.Before(*e.EndsAt) {
		p = "ENDED"
	} else if !now.Before(*e.StartsAt) {
		p = "LIVE"
	}
	e.Phase = &p
}
func versionTag(v int64) string { return `"` + strconv.FormatInt(v, 10) + `"` }
