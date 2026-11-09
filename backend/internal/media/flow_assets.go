package media

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type FlowConfig struct {
	MaxBytes     int64
	MaxDimension int
	Timeout      time.Duration
}

func DefaultFlowConfig() FlowConfig { return FlowConfig{32 * 1024 * 1024, 1920, 90 * time.Second} }
func ParseFlowConfig(get func(string) string) (FlowConfig, error) {
	c := DefaultFlowConfig()
	if v := get("FLOW_MEDIA_MAX_BYTES"); v != "" {
		n, e := strconv.ParseInt(v, 10, 64)
		if e != nil || n < 1024*1024 || n > 32*1024*1024 {
			return c, fmt.Errorf("FLOW_MEDIA_MAX_BYTES inválido")
		}
		c.MaxBytes = n
	}
	if v := get("FLOW_MEDIA_MAX_DIMENSION"); v != "" {
		n, e := strconv.Atoi(v)
		if e != nil || n < 320 || n > 4096 {
			return c, fmt.Errorf("FLOW_MEDIA_MAX_DIMENSION inválido")
		}
		c.MaxDimension = n
	}
	return c, nil
}
func (s *Service) ConfigureFlows(c FlowConfig) { s.flow = c }

type FlowAsset struct {
	ID           string  `json:"id"`
	ExperienceID string  `json:"experience_id"`
	Status       string  `json:"status"`
	ContentType  string  `json:"content_type"`
	SizeBytes    int64   `json:"size_bytes"`
	Width        *int32  `json:"width"`
	Height       *int32  `json:"height"`
	DurationMS   *int32  `json:"duration_ms"`
	FailureCode  *string `json:"failure_code"`
}

func assetView(u dbgen.MediaFlowAsset) FlowAsset {
	out := FlowAsset{ID: textID(u.ID), ExperienceID: textID(u.ExperienceID), Status: u.Status, ContentType: u.ContentType, SizeBytes: u.SizeBytes}
	if u.Width.Valid {
		out.Width = &u.Width.Int32
	}
	if u.Height.Valid {
		out.Height = &u.Height.Int32
	}
	if u.DurationMs.Valid {
		out.DurationMS = &u.DurationMs.Int32
	}
	if u.FailureCode.Valid {
		out.FailureCode = &u.FailureCode.String
	}
	return out
}
func (s *Service) InitiateFlow(ctx context.Context, session *identity.Session, eid, key string, in InitiateRequest, requestID string) (Initiated, error) {
	var out Initiated
	if (eid != "" && !id(eid).Valid) || !id(key).Valid {
		return out, identity.ErrInvalid
	}
	if in.SizeBytes < 1 || in.SizeBytes > s.flow.MaxBytes || ((in.ContentType == "image/jpeg" || in.ContentType == "image/png") && in.SizeBytes > MaxBytes) {
		return out, ErrInvalid
	}
	if in.ContentType != "image/jpeg" && in.ContentType != "image/png" && in.ContentType != "video/mp4" && in.ContentType != "video/quicktime" {
		return out, ErrInvalid
	}
	raw, _ := json.Marshal(struct {
		Experience string
		Input      InitiateRequest
	}{eid, in})
	hash := sha256.Sum256(raw)
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, session); e != nil {
			return e
		}
		q := dbgen.New(tx)
		if eid != "" {
			if _, e := q.LockExperience(ctx, id(eid)); e != nil {
				return identity.ErrNotFound
			}
			doc, e := q.GetExperience(ctx, id(eid))
			if e != nil {
				return e
			}
			var owner struct {
				Creator string `json:"creator_user_id"`
				Status  string `json:"status"`
			}
			if e = json.Unmarshal(doc, &owner); e != nil {
				return e
			}
			if owner.Creator != session.UserID {
				return identity.ErrNotFound
			}
			if owner.Status != "DRAFT" && owner.Status != "PUBLISHED" {
				return identity.ErrInvalid
			}
		} else {
			active, e := q.SocialActive(ctx, id(session.UserID))
			if e != nil {
				return e
			}
			if !active {
				return identity.ErrRestricted
			}
		}
		u, e := q.FindFlowAssetKey(ctx, dbgen.FindFlowAssetKeyParams{OwnerUserID: id(session.UserID), IdempotencyKey: id(key)})
		if e != nil && !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
		if e == nil {
			if !bytes.Equal(hash[:], u.RequestHash) {
				return ErrConflict
			}
			if u.Status != "UPLOADING" {
				return ErrPending
			}
			if !u.ExpiresAt.Time.After(time.Now()) {
				return ErrExpired
			}
		} else {
			count, e := q.MediaUploadRate(ctx, id(session.UserID))
			if e != nil {
				return e
			}
			if int(count) > s.daily {
				return identity.ErrRate
			}
			uid := newID()
			stem := "flows/" + textID(uid)
			expiry := pgtype.Timestamptz{Time: time.Now().UTC().Add(5 * time.Minute), Valid: true}
			if eid == "" {
				e = q.InsertSocialAsset(ctx, dbgen.InsertSocialAssetParams{ID: uid, OwnerUserID: id(session.UserID), IdempotencyKey: id(key), RequestHash: hash[:], ContentType: in.ContentType, SizeBytes: in.SizeBytes, StagingKey: stem + "/staging", ObjectKey: stem + "/media", PosterKey: stem + "/poster", ExpiresAt: expiry})
			} else {
				e = q.InsertFlowAsset(ctx, dbgen.InsertFlowAssetParams{ID: uid, ExperienceID: id(eid), OwnerUserID: id(session.UserID), IdempotencyKey: id(key), RequestHash: hash[:], ContentType: in.ContentType, SizeBytes: in.SizeBytes, StagingKey: stem + "/staging", ObjectKey: stem + "/media", PosterKey: stem + "/poster", ExpiresAt: expiry})
			}
			if e != nil {
				return e
			}
			u, e = q.GetFlowAsset(ctx, uid)
			if e != nil {
				return e
			}
			if e = flowAudit(ctx, q, u, "flow.media.initiated", requestID); e != nil {
				return e
			}
		}
		out.MediaID = textID(u.ID)
		out.Upload, e = s.storage.authorize(ctx, u.StagingKey, u.ContentType, u.SizeBytes, u.ExpiresAt.Time)
		return e
	})
	return out, err
}
func flowAudit(ctx context.Context, q *dbgen.Queries, u dbgen.MediaFlowAsset, action, req string) error {
	if u.Purpose == "SOCIAL" {
		event := "social.media." + strings.TrimPrefix(action, "flow.media.")
		if e := q.SocialAudit(ctx, dbgen.SocialAuditParams{ID: newID(), Actor: textID(u.OwnerUserID), ResourceID: u.ID, Action: event, RequestID: req, Details: []byte(`{}`)}); e != nil {
			return e
		}
		payload, _ := json.Marshal(map[string]any{"resource_id": textID(u.ID), "actor_user_id": textID(u.OwnerUserID)})
		return q.AppendOutbox(ctx, dbgen.AppendOutboxParams{EventID: newID(), EventType: event, SchemaVersion: 1, AggregateID: u.ID, OccurredAt: pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}, Payload: payload})
	}
	return q.InsertFlowAudit(ctx, dbgen.InsertFlowAuditParams{ID: newID(), ExperienceID: u.ExperienceID, ActorUserID: u.OwnerUserID, Action: action, Version: 0, RequestID: req, Details: []byte(`{}`)})
}
func (s *Service) FlowAsset(ctx context.Context, session *identity.Session, eid, aid string) (FlowAsset, error) {
	if session == nil {
		return FlowAsset{}, identity.ErrUnauthorized
	}
	u, e := dbgen.New(s.pool).GetFlowAsset(ctx, id(aid))
	if errors.Is(e, pgx.ErrNoRows) {
		return FlowAsset{}, identity.ErrNotFound
	}
	if e != nil {
		return FlowAsset{}, e
	}
	if textID(u.OwnerUserID) != session.UserID || assetExperience(u) != eid {
		return FlowAsset{}, identity.ErrNotFound
	}
	return assetView(u), nil
}
func (s *Service) ConfirmFlow(ctx context.Context, session *identity.Session, eid, aid, req string) (FlowAsset, error) {
	var out FlowAsset
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, session); e != nil {
			return e
		}
		q := dbgen.New(tx)
		if eid == "" {
			ok, e := q.SocialActive(ctx, id(session.UserID))
			if e != nil {
				return e
			}
			if !ok {
				return identity.ErrRestricted
			}
		}
		u, e := q.LockFlowAsset(ctx, id(aid))
		if errors.Is(e, pgx.ErrNoRows) {
			return identity.ErrNotFound
		}
		if e != nil {
			return e
		}
		if textID(u.OwnerUserID) != session.UserID || assetExperience(u) != eid {
			return identity.ErrNotFound
		}
		if u.Status == "UPLOADING" {
			if !u.ExpiresAt.Time.After(time.Now()) {
				return ErrExpired
			}
			if e = q.QueueFlowAsset(ctx, u.ID); e != nil {
				return e
			}
			u.Status = "PROCESSING"
			if e = flowAudit(ctx, q, u, "flow.media.queued", req); e != nil {
				return e
			}
		}
		out = assetView(u)
		return nil
	})
	return out, err
}

// BindFlow validates ownership, type and processing state under a row lock shared
// with cleanup. It also permits a pending asset so creators can leave the page.
func (s *Service) BindFlow(ctx context.Context, tx pgx.Tx, eid, owner string, aid *string, video bool) error {
	if aid == nil {
		return nil
	}
	u, e := dbgen.New(tx).LockFlowAsset(ctx, id(*aid))
	if e != nil {
		return ErrOwnership
	}
	isVideo := u.ContentType == "video/mp4" || u.ContentType == "video/quicktime"
	if assetExperience(u) != eid || textID(u.OwnerUserID) != owner || isVideo != video || (u.Status != "PROCESSING" && u.Status != "READY") {
		return ErrOwnership
	}
	return nil
}
func (s *Service) CleanupFlows(ctx context.Context) (int, error) {
	n := 0
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		q := dbgen.New(tx)
		rows, e := q.FlowAssetCleanupCandidates(ctx)
		if e != nil {
			return e
		}
		for _, u := range rows {
			if !u.StagingCleanedAt.Valid {
				if e = s.storage.remove(ctx, u.StagingKey); e != nil {
					return e
				}
				if e = q.FlowAssetStagingCleaned(ctx, u.ID); e != nil {
					return e
				}
			}
			bound, e := q.FlowAssetIsBound(ctx, u.ID)
			if e != nil {
				return e
			}
			if !bound && u.CreatedAt.Time.Before(time.Now().Add(-24*time.Hour)) {
				for _, key := range []string{u.ObjectKey, u.PosterKey} {
					if e = s.storage.remove(ctx, key); e != nil {
						return e
					}
				}
				if e = q.DeleteFlowAsset(ctx, u.ID); e != nil {
					return e
				}
				if e = flowAudit(ctx, q, u, "flow.media.orphan.deleted", "maintenance"); e != nil {
					return e
				}
			}
			n++
		}
		if e := q.DeleteFlowTombstones(ctx); e != nil {
			return e
		}
		return q.CleanupFlowAudit(ctx)
	})
	return n, err
}

// Social uploads share the durable media queue, processor, limits and storage.
func assetExperience(u dbgen.MediaFlowAsset) string {
	if !u.ExperienceID.Valid {
		return ""
	}
	return textID(u.ExperienceID)
}
func (s *Service) InitiateSocial(ctx context.Context, a *identity.Session, key string, in InitiateRequest, req string) (Initiated, error) {
	return s.InitiateFlow(ctx, a, "", key, in, req)
}
func (s *Service) SocialAsset(ctx context.Context, a *identity.Session, aid string) (FlowAsset, error) {
	return s.FlowAsset(ctx, a, "", aid)
}
func (s *Service) ConfirmSocial(ctx context.Context, a *identity.Session, aid, req string) (FlowAsset, error) {
	return s.ConfirmFlow(ctx, a, "", aid, req)
}
