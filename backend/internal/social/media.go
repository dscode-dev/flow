package social

import (
	"context"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/database/dbgen"
	"net/url"
	"time"
)

type mediaTicket struct {
	Post, Asset, User, Session string
	Version                    int64
	Poster                     bool
	Expires                    time.Time
}

func (s *Service) decorate(d map[string]any, a *identity.Session) {
	now := time.Now().UTC()
	d["as_of"] = now
	d["valid_until"] = now.Add(30 * time.Second)
	items, _ := d["media"].([]any)
	for _, v := range items {
		m := v.(map[string]any)
		if m["status"] != "READY" {
			continue
		}
		t := mediaTicket{Post: d["id"].(string), Asset: m["id"].(string), User: a.UserID, Session: a.ID, Version: int64(d["version"].(float64)), Expires: now.Add(30 * time.Second)}
		base := "v1/social/posts/" + t.Post + "/media/" + t.Asset + "/content?ticket="
		m["url"] = base + url.QueryEscape(s.sign(t))
		if m["duration_ms"] != nil {
			t.Poster = true
			m["poster_url"] = base + url.QueryEscape(s.sign(t))
		}
		m["expires_at"] = t.Expires
	}
}

// Signed short-lived capability, never an S3 GET. Every range request rechecks
// session, current post version, graph, participation, lifecycle and moderation.
func (s *Service) Content(ctx context.Context, pid, aid, raw, rangeHeader string) (media.Stream, error) {
	var t mediaTicket
	now := time.Now().UTC()
	if !s.verify(raw, &t) || t.Post != pid || t.Asset != aid || !t.Expires.After(now) || t.Expires.After(now.Add(31*time.Second)) {
		return media.Stream{}, identity.ErrNotFound
	}
	q := dbgen.New(s.pool)
	ok, e := q.FlowMediaSessionActive(ctx, dbgen.FlowMediaSessionActiveParams{ID: id(t.Session), UserID: id(t.User)})
	if e != nil {
		return media.Stream{}, e
	}
	if !ok {
		return media.Stream{}, identity.ErrNotFound
	}
	d, e := loadPost(ctx, q, pid, t.User)
	if e != nil {
		return media.Stream{}, e
	}
	if int64(d["version"].(float64)) != t.Version {
		return media.Stream{}, identity.ErrNotFound
	}
	list, _ := d["media"].([]any)
	for _, v := range list {
		m := v.(map[string]any)
		if m["id"] == aid && m["status"] == "READY" && (!t.Poster || m["duration_ms"] != nil) {
			return s.media.StreamFlow(ctx, aid, t.Poster, rangeHeader)
		}
	}
	return media.Stream{}, identity.ErrNotFound
}

// OwnMedia exposes no made-up Experience ID. A processed preview is owner-only,
// session-bound and subject to the same revocation and no-store policy as posts.
func (s *Service) OwnMedia(ctx context.Context, a *identity.Session, aid string) (map[string]any, error) {
	if a == nil {
		return nil, identity.ErrUnauthorized
	}
	q := dbgen.New(s.pool)
	allowed, e := q.SocialAssetAllowed(ctx, dbgen.SocialAssetAllowedParams{AssetID: id(aid), Column2: id(a.UserID)})
	if e != nil {
		return nil, e
	}
	if !allowed {
		return nil, identity.ErrNotFound
	}
	if e := connected(ctx, q, a.UserID, a.UserID); e != nil {
		return nil, e
	}
	u, e := q.GetFlowAsset(ctx, id(aid))
	if e != nil || u.OwnerUserID != id(a.UserID) || u.Purpose != "SOCIAL" || u.Status == "DELETED" {
		return nil, identity.ErrNotFound
	}
	d := map[string]any{"id": aid, "status": u.Status, "content_type": u.ContentType, "size_bytes": u.SizeBytes, "width": nil, "height": nil, "duration_ms": nil, "failure_code": nil, "sha256": nil, "variant": "sanitized-v1"}
	if u.Width.Valid {
		d["width"] = u.Width.Int32
	}
	if u.Height.Valid {
		d["height"] = u.Height.Int32
	}
	if u.DurationMs.Valid {
		d["duration_ms"] = u.DurationMs.Int32
		d["content_type"] = "video/mp4"
	}
	if u.FailureCode.Valid {
		d["failure_code"] = u.FailureCode.String
	}
	if u.Sha256.Valid {
		d["sha256"] = u.Sha256.String
	}
	if u.VerifiedSize.Valid {
		d["size_bytes"] = u.VerifiedSize.Int64
	}
	now := time.Now().UTC()
	d["as_of"] = now
	if u.Status == "READY" {
		t := mediaTicket{Asset: aid, User: a.UserID, Session: a.ID, Expires: now.Add(30 * time.Second)}
		base := "v1/social/media/" + aid + "/content?ticket="
		d["url"] = base + url.QueryEscape(s.sign(t))
		if u.DurationMs.Valid {
			t.Poster = true
			d["poster_url"] = base + url.QueryEscape(s.sign(t))
		}
		d["expires_at"] = t.Expires
	}
	return d, nil
}
func (s *Service) Preview(ctx context.Context, aid, raw, rangeHeader string) (media.Stream, error) {
	var t mediaTicket
	now := time.Now().UTC()
	if !s.verify(raw, &t) || t.Asset != aid || t.Post != "" || t.Version != 0 || !t.Expires.After(now) || t.Expires.After(now.Add(31*time.Second)) {
		return media.Stream{}, identity.ErrNotFound
	}
	q := dbgen.New(s.pool)
	active, e := q.FlowMediaSessionActive(ctx, dbgen.FlowMediaSessionActiveParams{ID: id(t.Session), UserID: id(t.User)})
	if e != nil {
		return media.Stream{}, e
	}
	if !active {
		return media.Stream{}, identity.ErrNotFound
	}
	if e = connected(ctx, q, t.User, t.User); e != nil {
		return media.Stream{}, e
	}
	allowed, e := q.SocialAssetAllowed(ctx, dbgen.SocialAssetAllowedParams{AssetID: id(aid), Column2: id(t.User)})
	if e != nil {
		return media.Stream{}, e
	}
	if !allowed {
		return media.Stream{}, identity.ErrNotFound
	}
	u, e := q.GetFlowAsset(ctx, id(aid))
	if e != nil || u.OwnerUserID != id(t.User) || u.Purpose != "SOCIAL" || u.Status != "READY" || (t.Poster && !u.DurationMs.Valid) {
		return media.Stream{}, identity.ErrNotFound
	}
	return s.media.StreamFlow(ctx, aid, t.Poster, rangeHeader)
}
