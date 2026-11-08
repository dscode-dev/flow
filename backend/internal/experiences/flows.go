package experiences

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type FlowItem struct {
	Experience     Experience `json:"experience"`
	Version        int64      `json:"presentation_version"`
	ImageKind      string     `json:"image_kind"`
	HasVideo       bool       `json:"has_video"`
	DurationMS     *int32     `json:"duration_ms"`
	ImageURL       string     `json:"image_url"`
	VideoURL       *string    `json:"video_url"`
	MediaExpiresAt time.Time  `json:"media_expires_at"`
}
type FlowsPage struct {
	Items       []FlowItem `json:"items"`
	NextCursor  *string    `json:"next_cursor"`
	AsOf        time.Time  `json:"as_of"`
	ValidUntil  time.Time  `json:"valid_until"`
	WindowHours int        `json:"window_hours"`
}
type mediaTicket struct {
	Experience, User, Session, Kind string
	Version, Presentation           int64
	Expires                         time.Time
}

func (s *Service) ticket(t mediaTicket) string {
	b, _ := json.Marshal(t)
	mac := hmac.New(sha256.New, s.config.CursorKey)
	mac.Write([]byte("flow.media.v1:"))
	mac.Write(b)
	return base64.RawURLEncoding.EncodeToString(b) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
func (s *Service) flowItem(session *identity.Session, r dbgen.GetEligibleFlowRow, now time.Time) (FlowItem, error) {
	rec, e := decodeRecord(r.Document)
	if e != nil {
		return FlowItem{}, e
	}
	exp := presentation(rec, session.UserID, now)
	exp.Description = ""
	out := FlowItem{Experience: exp, Version: r.PresentationVersion, ImageKind: r.ImageKind, HasVideo: r.VideoAssetID.Valid, MediaExpiresAt: now.Add(30 * time.Second)}
	if exp.EndsAt.Before(out.MediaExpiresAt) {
		out.MediaExpiresAt = *exp.EndsAt
	}
	if r.DurationMs.Valid {
		out.DurationMS = &r.DurationMs.Int32
	}
	capURL := func(kind string) string {
		return "v1/flows/" + exp.ID + "/content?ticket=" + url.QueryEscape(s.ticket(mediaTicket{exp.ID, session.UserID, session.ID, kind, exp.Version, r.PresentationVersion, out.MediaExpiresAt}))
	}
	out.ImageURL = capURL("image")
	if out.HasVideo {
		v := capURL("video")
		out.VideoURL = &v
	}
	return out, nil
}
func (s *Service) flowRow(ctx context.Context, eid string, now time.Time) (dbgen.GetEligibleFlowRow, error) {
	r, e := dbgen.New(s.pool).GetEligibleFlow(ctx, dbgen.GetEligibleFlowParams{ID: id(eid), EndsAt: ts(now), StartsAt: ts(now.Add(time.Duration(s.config.FlowsWindowHours) * time.Hour))})
	if errors.Is(e, pgx.ErrNoRows) {
		e = identity.ErrNotFound
	}
	return r, e
}
func (s *Service) Flow(ctx context.Context, session *identity.Session, eid string) (FlowItem, error) {
	if session == nil {
		return FlowItem{}, identity.ErrUnauthorized
	}
	now := time.Now().UTC()
	r, e := s.flowRow(ctx, eid, now)
	if e != nil {
		return FlowItem{}, e
	}
	return s.flowItem(session, r, now)
}
func (s *Service) Flows(ctx context.Context, session *identity.Session, f DiscoveryFilter, raw string) (FlowsPage, error) {
	now := time.Now().UTC()
	out := FlowsPage{Items: []FlowItem{}, AsOf: now, ValidUntil: now.Add(time.Minute), WindowHours: s.config.FlowsWindowHours}
	if session == nil {
		return out, identity.ErrUnauthorized
	}
	c, e := s.discoveryCursor(session, f, raw, "flows.v1")
	if e != nil {
		return out, e
	}
	center := Location{}
	if f.Spatial.Center != nil {
		center = *f.Spatial.Center
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	rows, e := dbgen.New(s.pool).ListFlows(ctx, dbgen.ListFlowsParams{Snapshot: ts(c.Snapshot), AsOf: ts(now), WindowEnd: ts(c.Snapshot.Add(time.Duration(s.config.FlowsWindowHours) * time.Hour)), CategoryFilter: f.Spatial.Category, Nearby: f.Spatial.Center != nil, Longitude: center.Longitude, Latitude: center.Latitude, RadiusM: f.Spatial.RadiusM, AfterRank: c.Rank, AfterTime: ts(c.Time), AfterID: id(c.ID), PageLimit: int32(f.Spatial.Limit + 1)})
	if e != nil {
		return out, e
	}
	more := len(rows) > f.Spatial.Limit
	if more {
		rows = rows[:f.Spatial.Limit]
	}
	for _, r := range rows {
		item, e := s.flowItem(session, dbgen.GetEligibleFlowRow{Document: r.Document, PresentationVersion: r.PresentationVersion, ImageKind: r.ImageKind, ImageAssetID: r.ImageAssetID, VideoAssetID: r.VideoAssetID, DurationMs: r.DurationMs, MediaWidth: r.MediaWidth, MediaHeight: r.MediaHeight}, now)
		if e != nil {
			return out, e
		}
		out.Items = append(out.Items, item)
		boundFreshness(&out.ValidUntil, item.Experience, now)
	}
	if more {
		last := rows[len(rows)-1]
		item := out.Items[len(out.Items)-1]
		c.ID = item.Experience.ID
		c.Time = *item.Experience.StartsAt
		c.Rank = last.PhaseRank
		next := s.signCursor(c)
		out.NextCursor = &next
	}
	return out, nil
}
func (s *Service) FlowContent(ctx context.Context, eid, raw, rangeHeader string) (media.Stream, error) {
	fail := identity.ErrNotFound
	if len(raw) > 2048 {
		return media.Stream{}, fail
	}
	parts := strings.Split(raw, ".")
	if len(parts) != 2 {
		return media.Stream{}, fail
	}
	b, e := base64.RawURLEncoding.DecodeString(parts[0])
	if e != nil {
		return media.Stream{}, fail
	}
	sig, e := base64.RawURLEncoding.DecodeString(parts[1])
	if e != nil {
		return media.Stream{}, fail
	}
	mac := hmac.New(sha256.New, s.config.CursorKey)
	mac.Write([]byte("flow.media.v1:"))
	mac.Write(b)
	var t mediaTicket
	now := time.Now().UTC()
	if !hmac.Equal(sig, mac.Sum(nil)) || json.Unmarshal(b, &t) != nil || t.Experience != eid || !t.Expires.After(now) || t.Expires.After(now.Add(31*time.Second)) || (t.Kind != "image" && t.Kind != "video") {
		return media.Stream{}, fail
	}
	active, e := dbgen.New(s.pool).FlowMediaSessionActive(ctx, dbgen.FlowMediaSessionActiveParams{ID: id(t.Session), UserID: id(t.User)})
	if e != nil {
		return media.Stream{}, e
	}
	if !active {
		return media.Stream{}, fail
	}
	r, e := s.flowRow(ctx, eid, now)
	if e != nil {
		return media.Stream{}, e
	}
	rec, e := decodeRecord(r.Document)
	if e != nil {
		return media.Stream{}, e
	}
	if rec.Version != t.Version || r.PresentationVersion != t.Presentation {
		return media.Stream{}, fail
	}
	uuidText := func(v pgtype.UUID) string { return strings.ToLower(v.String()) }
	if t.Kind == "video" {
		if !r.VideoAssetID.Valid {
			return media.Stream{}, fail
		}
		return s.media.StreamFlow(ctx, uuidText(r.VideoAssetID), false, rangeHeader)
	}
	switch r.ImageKind {
	case "image":
		return s.media.StreamFlow(ctx, uuidText(r.ImageAssetID), false, rangeHeader)
	case "poster":
		return s.media.StreamFlow(ctx, uuidText(r.VideoAssetID), true, rangeHeader)
	default:
		if rec.CoverMediaID == nil {
			return media.Stream{}, fail
		}
		return s.media.StreamCover(ctx, *rec.CoverMediaID, rangeHeader)
	}
}

type PresentationInput struct {
	Enabled         *bool   `json:"enabled"`
	UnlistedConsent bool    `json:"unlisted_consent"`
	ImageAssetID    *string `json:"image_asset_id"`
	VideoAssetID    *string `json:"video_asset_id"`
}
type FlowPresentation struct {
	ExperienceID      string     `json:"experience_id"`
	Enabled           bool       `json:"enabled"`
	UnlistedConsentAt *time.Time `json:"unlisted_consent_at"`
	ImageAssetID      *string    `json:"image_asset_id"`
	VideoAssetID      *string    `json:"video_asset_id"`
	Version           int64      `json:"version"`
}

func presentationView(eid string, p dbgen.ExperiencesFlowPresentation) FlowPresentation {
	out := FlowPresentation{ExperienceID: eid, Enabled: p.Enabled, Version: p.Version}
	if p.UnlistedConsentAt.Valid {
		out.UnlistedConsentAt = &p.UnlistedConsentAt.Time
	}
	if p.ImageAssetID.Valid {
		v := p.ImageAssetID.String()
		out.ImageAssetID = &v
	}
	if p.VideoAssetID.Valid {
		v := p.VideoAssetID.String()
		out.VideoAssetID = &v
	}
	return out
}
func (s *Service) Presentation(ctx context.Context, session *identity.Session, eid string) (FlowPresentation, error) {
	if session == nil {
		return FlowPresentation{}, identity.ErrUnauthorized
	}
	r, e := load(ctx, dbgen.New(s.pool), eid)
	if e != nil {
		return FlowPresentation{}, e
	}
	if r.CreatorUserID != session.UserID {
		return FlowPresentation{}, identity.ErrNotFound
	}
	p, e := dbgen.New(s.pool).GetFlowPresentation(ctx, id(eid))
	if errors.Is(e, pgx.ErrNoRows) {
		return FlowPresentation{ExperienceID: eid, Enabled: r.Visibility == "PUBLIC", Version: 0}, nil
	}
	return presentationView(eid, p), e
}
func (s *Service) SavePresentation(ctx context.Context, session *identity.Session, eid string, version int64, in PresentationInput, req string) (FlowPresentation, error) {
	var out FlowPresentation
	if in.Enabled == nil {
		return out, ErrInvalid
	}
	for _, v := range []*string{in.ImageAssetID, in.VideoAssetID} {
		if v != nil && !id(*v).Valid {
			return out, ErrInvalid
		}
	}
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, session); e != nil {
			return e
		}
		q := dbgen.New(tx)
		if _, e := q.LockExperience(ctx, id(eid)); e != nil {
			return identity.ErrNotFound
		}
		r, e := load(ctx, q, eid)
		if e != nil {
			return e
		}
		if r.CreatorUserID != session.UserID {
			return identity.ErrNotFound
		}
		if r.Status != "DRAFT" && r.Status != "PUBLISHED" {
			return ErrTransition
		}
		if r.ModerationStatus != "VISIBLE" {
			return ErrPublishing
		}
		p, e := q.GetFlowPresentation(ctx, id(eid))
		if errors.Is(e, pgx.ErrNoRows) {
			p = dbgen.ExperiencesFlowPresentation{ExperienceID: id(eid), Enabled: true}
		} else if e != nil {
			return e
		}
		if p.Version != version {
			return ErrVersion
		}
		if *in.Enabled {
			if e = s.publishingAllowed(ctx, q, session.UserID); e != nil {
				return e
			}
		}
		if *in.Enabled && r.Visibility == "PRIVATE" {
			return ErrPublishing
		}
		if *in.Enabled && r.Visibility == "UNLISTED" && !in.UnlistedConsent {
			return ErrValidation
		}
		if !*in.Enabled {
			p.UnlistedConsentAt = pgtype.Timestamptz{}
			p.UnlistedConsentActor = pgtype.UUID{}
		} else if r.Visibility == "UNLISTED" && in.UnlistedConsent && !p.UnlistedConsentAt.Valid {
			p.UnlistedConsentAt = ts(time.Now())
			p.UnlistedConsentActor = id(session.UserID)
		}
		if in.ImageAssetID == nil || *in.ImageAssetID != p.ImageAssetID.String() {
			if e = s.media.BindFlow(ctx, tx, eid, session.UserID, in.ImageAssetID, false); e != nil {
				return e
			}
		}
		if in.VideoAssetID == nil || *in.VideoAssetID != p.VideoAssetID.String() {
			if e = s.media.BindFlow(ctx, tx, eid, session.UserID, in.VideoAssetID, true); e != nil {
				return e
			}
		}
		p.Enabled = *in.Enabled
		p.ImageAssetID = pgtype.UUID{}
		p.VideoAssetID = pgtype.UUID{}
		if in.ImageAssetID != nil {
			p.ImageAssetID = id(*in.ImageAssetID)
		}
		if in.VideoAssetID != nil {
			p.VideoAssetID = id(*in.VideoAssetID)
		}
		// Repeating a PUT with the current version is safe; stale writes conflict.
		p.Version++
		if e = q.SaveFlowPresentation(ctx, dbgen.SaveFlowPresentationParams{ExperienceID: p.ExperienceID, Enabled: p.Enabled, UnlistedConsentAt: p.UnlistedConsentAt, UnlistedConsentActor: p.UnlistedConsentActor, ImageAssetID: p.ImageAssetID, VideoAssetID: p.VideoAssetID, Version: p.Version}); e != nil {
			return e
		}
		details, _ := json.Marshal(map[string]any{"enabled": p.Enabled, "unlisted_consent": p.UnlistedConsentAt.Valid, "visibility": r.Visibility, "image_asset_id": in.ImageAssetID, "video_asset_id": in.VideoAssetID})
		if e = q.InsertFlowAudit(ctx, dbgen.InsertFlowAuditParams{ID: newID(), ExperienceID: id(eid), ActorUserID: id(session.UserID), Action: "flow.presentation.updated", Version: p.Version, RequestID: req, Details: details}); e != nil {
			return e
		}
		out = presentationView(eid, p)
		return nil
	})
	return out, err
}
