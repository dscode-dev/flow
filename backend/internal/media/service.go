package media

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"image"
	"image/jpeg"
	"image/png"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool       *pgxpool.Pool
	storage    *Storage
	daily      int
	processing chan struct{}
}

func New(pool *pgxpool.Pool, storage *Storage, daily int) *Service {
	return &Service{pool: pool, storage: storage, daily: daily, processing: make(chan struct{}, 2)}
}
func id(s string) pgtype.UUID      { u, e := uuid.Parse(s); return pgtype.UUID{Bytes: u, Valid: e == nil} }
func newID() pgtype.UUID           { return pgtype.UUID{Bytes: uuid.Must(uuid.NewV7()), Valid: true} }
func textID(id pgtype.UUID) string { return uuid.UUID(id.Bytes).String() }

type InitiateRequest struct {
	ContentType string `json:"content_type"`
	SizeBytes   int64  `json:"size_bytes"`
}
type Initiated struct {
	MediaID string        `json:"media_id"`
	Upload  Authorization `json:"upload"`
}
type Verified struct {
	ID          string `json:"id"`
	Status      string `json:"status"`
	ContentType string `json:"content_type"`
	SizeBytes   int64  `json:"size_bytes"`
	Width       int32  `json:"width"`
	Height      int32  `json:"height"`
	SHA256      string `json:"sha256"`
}

func verified(u dbgen.MediaUpload) Verified {
	return Verified{textID(u.ID), u.Status, u.ContentType, u.VerifiedSize.Int64, u.Width.Int32, u.Height.Int32, u.Sha256.String}
}
func audit(ctx context.Context, q *dbgen.Queries, u dbgen.MediaUpload, action, requestID string) error {
	return q.InsertMediaAudit(ctx, dbgen.InsertMediaAuditParams{ID: newID(), MediaID: u.ID, ActorUserID: u.OwnerUserID, Action: action, RequestID: requestID})
}

func (s *Service) Initiate(ctx context.Context, session *identity.Session, key string, in InitiateRequest, requestID string) (Initiated, error) {
	var out Initiated
	if !id(key).Valid {
		return out, identity.ErrInvalid
	}
	if in.SizeBytes < 1 || in.SizeBytes > MaxBytes || (in.ContentType != "image/jpeg" && in.ContentType != "image/png") {
		return out, ErrInvalid
	}
	if s.storage == nil {
		return out, ErrUnavailable
	}
	body, _ := json.Marshal(in)
	hash := sha256.Sum256(body)
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, session); e != nil {
			return e
		}
		q := dbgen.New(tx)
		u, e := q.FindMediaUploadKey(ctx, dbgen.FindMediaUploadKeyParams{OwnerUserID: id(session.UserID), IdempotencyKey: id(key)})
		if e != nil && !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
		if e == nil {
			if !bytes.Equal(u.RequestHash, hash[:]) {
				return ErrConflict
			}
			if !u.ExpiresAt.Time.After(time.Now()) {
				return ErrExpired
			}
			if u.Status != "UPLOADING" {
				return ErrPending
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
			stem := textID(uid)
			u = dbgen.MediaUpload{ID: uid, OwnerUserID: id(session.UserID), ContentType: in.ContentType, SizeBytes: in.SizeBytes, StagingKey: "staging/" + stem, ObjectKey: "verified/" + stem, ExpiresAt: pgtype.Timestamptz{Time: time.Now().UTC().Add(5 * time.Minute), Valid: true}}
			if e = q.InsertMediaUpload(ctx, dbgen.InsertMediaUploadParams{ID: u.ID, OwnerUserID: u.OwnerUserID, IdempotencyKey: id(key), RequestHash: hash[:], ContentType: in.ContentType, SizeBytes: in.SizeBytes, StagingKey: u.StagingKey, ObjectKey: u.ObjectKey, ExpiresAt: u.ExpiresAt}); e != nil {
				return e
			}
			if e = audit(ctx, q, u, "media.upload.initiated", requestID); e != nil {
				return e
			}
		}
		out.MediaID = textID(u.ID)
		out.Upload, e = s.storage.authorize(ctx, u.StagingKey, u.ContentType, u.SizeBytes, u.ExpiresAt.Time)
		return e
	})
	return out, err
}

// sanitize fully decodes bounded pixels then re-encodes, discarding metadata,
// trailing polyglot data and unsupported formats before anything is attachable.
func sanitize(raw []byte, ct string) ([]byte, int, int, error) {
	cfg, format, e := image.DecodeConfig(bytes.NewReader(raw))
	want := "png"
	if ct == "image/jpeg" {
		want = "jpeg"
	}
	if e != nil || format != want || cfg.Width < 1 || cfg.Height < 1 || cfg.Width > 4096 || cfg.Height > 4096 || int64(cfg.Width)*int64(cfg.Height) > 12000000 {
		return nil, 0, 0, ErrInvalid
	}
	decoded, _, e := image.Decode(bytes.NewReader(raw))
	if e != nil {
		return nil, 0, 0, ErrInvalid
	}
	var buf bytes.Buffer
	if want == "jpeg" {
		e = jpeg.Encode(&buf, decoded, &jpeg.Options{Quality: 85})
	} else {
		e = png.Encode(&buf, decoded)
	}
	if e != nil || int64(buf.Len()) > MaxBytes {
		return nil, 0, 0, ErrInvalid
	}
	return buf.Bytes(), cfg.Width, cfg.Height, nil
}
func (s *Service) Confirm(ctx context.Context, session *identity.Session, mediaID, requestID string) (Verified, error) {
	var out Verified
	var rejected bool
	if !id(mediaID).Valid {
		return out, identity.ErrInvalid
	}
	// Bound image-decoding memory/CPU across accounts on this API instance.
	select {
	case s.processing <- struct{}{}:
		defer func() { <-s.processing }()
	default:
		return out, ErrUnavailable
	}
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, session); e != nil {
			return e
		}
		q := dbgen.New(tx)
		u, e := q.LockMediaUpload(ctx, id(mediaID))
		if errors.Is(e, pgx.ErrNoRows) {
			return identity.ErrNotFound
		}
		if e != nil {
			return e
		}
		if u.OwnerUserID != id(session.UserID) {
			return identity.ErrNotFound
		}
		if u.Status == "READY" {
			out = verified(u)
			return nil
		}
		if u.Status != "UPLOADING" {
			return ErrPending
		}
		if !u.ExpiresAt.Time.After(time.Now()) {
			return ErrExpired
		}
		raw, ct, e := s.storage.read(ctx, u.StagingKey, MaxBytes)
		if e != nil && !errors.Is(e, ErrInvalid) {
			return e
		}
		var b []byte
		var width, height int
		if e == nil && ct == u.ContentType && int64(len(raw)) == u.SizeBytes {
			b, width, height, e = sanitize(raw, ct)
		} else {
			e = ErrInvalid
		}
		if e != nil {
			rejected = true
			if e = q.RejectMediaUpload(ctx, u.ID); e != nil {
				return e
			}
			return audit(ctx, q, u, "media.upload.rejected", requestID)
		}
		// Only the server can write verified/. Replaying the POST can at most replace
		// staging; it cannot change a READY cover, even after association.
		if e = s.storage.write(ctx, u.ObjectKey, ct, b); e != nil {
			return e
		}
		hash := sha256.Sum256(b)
		p := dbgen.ReadyMediaUploadParams{ID: u.ID, VerifiedSize: pgtype.Int8{Int64: int64(len(b)), Valid: true}, Width: pgtype.Int4{Int32: int32(width), Valid: true}, Height: pgtype.Int4{Int32: int32(height), Valid: true}, Sha256: pgtype.Text{String: hex.EncodeToString(hash[:]), Valid: true}}
		if e = q.ReadyMediaUpload(ctx, p); e != nil {
			return e
		}
		if e = audit(ctx, q, u, "media.upload.confirmed", requestID); e != nil {
			return e
		}
		u.Status = "READY"
		u.VerifiedSize = p.VerifiedSize
		u.Width = p.Width
		u.Height = p.Height
		u.Sha256 = p.Sha256
		out = verified(u)
		return nil
	})
	if err == nil && rejected {
		err = ErrInvalid
	}
	return out, err
}

// Bind is Media's synchronous authorization boundary inside the Experience
// transaction. Row locking serializes association with orphan cleanup.
func (s *Service) Bind(ctx context.Context, tx pgx.Tx, experienceID, owner string, mediaID *string) error {
	q := dbgen.New(tx)
	if mediaID == nil {
		return q.RemoveMediaBinding(ctx, id(experienceID))
	}
	u, e := q.LockMediaUpload(ctx, id(*mediaID))
	if errors.Is(e, pgx.ErrNoRows) {
		return ErrOwnership
	}
	if e != nil {
		return e
	}
	if u.OwnerUserID != id(owner) || u.Status != "READY" {
		return ErrOwnership
	}
	return q.SetMediaBinding(ctx, dbgen.SetMediaBindingParams{ExperienceID: id(experienceID), MediaID: u.ID, OwnerUserID: id(owner)})
}

// ReadCover is only called after Experiences authorizes the containing resource.
func (s *Service) ReadCover(ctx context.Context, mediaID string) ([]byte, string, error) {
	u, e := dbgen.New(s.pool).GetMediaUpload(ctx, id(mediaID))
	if errors.Is(e, pgx.ErrNoRows) {
		return nil, "", identity.ErrNotFound
	}
	if e != nil {
		return nil, "", e
	}
	if u.Status != "READY" {
		return nil, "", identity.ErrNotFound
	}
	return s.storage.read(ctx, u.ObjectKey, MaxBytes)
}

// Cleanup runs bounded batches, retryable on storage failure. Bound READY files
// survive; staging is removed after the authorization expires plus one hour.
// Database tombstones retain idempotency/diagnostics, never object contents.
func (s *Service) Cleanup(ctx context.Context) (int, error) {
	if s.storage == nil {
		return 0, ErrUnavailable
	}
	count := 0
	err := database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		q := dbgen.New(tx)
		rows, e := q.MediaCleanupCandidates(ctx)
		if e != nil {
			return e
		}
		for _, u := range rows {
			if u.ExpiresAt.Time.Before(time.Now().Add(-time.Hour)) && !u.StagingCleanedAt.Valid {
				if e = s.storage.remove(ctx, u.StagingKey); e != nil {
					return e
				}
				if e = q.MediaStagingCleaned(ctx, u.ID); e != nil {
					return e
				}
			}
			bound, e := q.MediaIsBound(ctx, u.ID)
			if e != nil {
				return e
			}
			if !bound && u.Status != "DELETED" && u.CreatedAt.Time.Before(time.Now().Add(-24*time.Hour)) {
				if e = s.storage.remove(ctx, u.ObjectKey); e != nil {
					return e
				}
				if e = q.DeleteMediaUpload(ctx, u.ID); e != nil {
					return e
				}
				if e = audit(ctx, q, u, "media.orphan.deleted", "maintenance"); e != nil {
					return e
				}
			}
			count++
		}
		if e = q.CleanupMediaRates(ctx); e != nil {
			return e
		}
		if e = q.CleanupMediaTombstones(ctx); e != nil {
			return e
		}
		return q.CleanupMediaAudit(ctx)
	})
	return count, err
}
