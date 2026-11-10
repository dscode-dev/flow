package social

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"fmt"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"strings"
	"time"
	"unicode/utf8"
)

type Service struct {
	pool   *pgxpool.Pool
	media  *media.Service
	config Config
}

func New(p *pgxpool.Pool, m *media.Service, c Config) *Service { return &Service{p, m, c} }
func id(s string) pgtype.UUID                                  { u, e := uuid.Parse(s); return pgtype.UUID{Bytes: u, Valid: e == nil} }
func newID() pgtype.UUID                                       { return id(uuid.Must(uuid.NewV7()).String()) }
func str(u pgtype.UUID) string                                 { return uuid.UUID(u.Bytes).String() }
func ts(t time.Time) pgtype.Timestamptz                        { return pgtype.Timestamptz{Time: t, Valid: true} }
func connected(ctx context.Context, q *dbgen.Queries, a, b string) error {
	v, e := q.SocialConnected(ctx, dbgen.SocialConnectedParams{Column1: id(a), Column2: id(b)})
	if e != nil {
		return e
	}
	if !v {
		return identity.ErrNotFound
	}
	return nil
}
func document(b []byte, e error) (map[string]any, error) {
	if errors.Is(e, pgx.ErrNoRows) || (e == nil && (len(b) == 0 || string(b) == "null")) {
		return nil, identity.ErrNotFound
	}
	if e != nil {
		return nil, e
	}
	var d map[string]any
	e = json.Unmarshal(b, &d)
	return d, e
}
func emit(ctx context.Context, q *dbgen.Queries, actor, resource, action, request string, details any) error {
	raw, e := json.Marshal(details)
	if e != nil {
		return e
	}
	if e = q.SocialAudit(ctx, dbgen.SocialAuditParams{ID: newID(), Actor: actor, ResourceID: id(resource), Action: action, RequestID: request, Details: raw}); e != nil {
		return e
	}
	p := map[string]any{"resource_id": resource}
	if id(actor).Valid {
		p["actor_user_id"] = actor
	}
	if d, ok := details.(map[string]any); ok {
		if v, ok := d["post_id"].(string); ok && id(v).Valid {
			p["post_id"] = v
		}
	}
	payload, _ := json.Marshal(p)
	return q.AppendOutbox(ctx, dbgen.AppendOutboxParams{EventID: newID(), EventType: action, SchemaVersion: 1, AggregateID: id(resource), OccurredAt: ts(time.Now().UTC()), Payload: payload})
}

// Actor/session lock serializes receipts. A pair lock serializes graph changes;
// the post lock serializes interactions and content/moderation, without counters.
func (s *Service) run(ctx context.Context, a *identity.Session, key, operation, req string, input any, fn func(context.Context, pgx.Tx, *dbgen.Queries) (string, error)) (map[string]any, error) {
	return s.runGuarded(ctx, a, key, operation, req, input, nil, fn)
}
func (s *Service) runGuarded(ctx context.Context, a *identity.Session, key, operation, req string, input any, guard func(context.Context, pgx.Tx, *dbgen.Queries) error, fn func(context.Context, pgx.Tx, *dbgen.Queries) (string, error)) (map[string]any, error) {
	if a == nil {
		return nil, identity.ErrUnauthorized
	}
	if !id(key).Valid {
		return nil, identity.ErrInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	n, e := dbgen.New(s.pool).SocialRate(ctx, id(a.UserID))
	if e != nil {
		return nil, e
	}
	if n > int32(s.config.MutationMinute) {
		return nil, identity.ErrRate
	}
	raw, _ := json.Marshal([]any{operation, input})
	hash := sha256.Sum256(raw)
	var out map[string]any
	e = database.InTransaction(ctx, s.pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, a); e != nil {
			return e
		}
		if _, e := tx.Exec(ctx, "SET LOCAL lock_timeout='2s'"); e != nil {
			return e
		}
		q := dbgen.New(tx)
		active, e := q.SocialActive(ctx, id(a.UserID))
		if e != nil {
			return e
		}
		if !active {
			return identity.ErrRestricted
		}
		if guard != nil {
			if e := guard(ctx, tx, q); e != nil {
				return e
			}
		}
		receipt, e := q.SocialReceipt(ctx, dbgen.SocialReceiptParams{ActorUserID: id(a.UserID), Key: id(key)})
		if e == nil {
			if !bytes.Equal(receipt.RequestHash, hash[:]) {
				return ErrConflict
			}
			return json.Unmarshal(receipt.Response, &out)
		}
		if !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
		resource, e := fn(ctx, tx, q)
		if e != nil {
			return e
		}
		out = map[string]any{"id": resource}
		b, _ := json.Marshal(out)
		return q.SocialSaveReceipt(ctx, dbgen.SocialSaveReceiptParams{ActorUserID: id(a.UserID), Key: id(key), RequestHash: hash[:], Response: b})
	})
	return out, e
}
func (s *Service) Create(ctx context.Context, a *identity.Session, key string, in Input, req string) (map[string]any, error) {
	in.Body = strings.TrimSpace(in.Body)
	if !utf8.ValidString(in.Body) || utf8.RuneCountInString(in.Body) > s.config.BodyLimit || len(in.MediaIDs) > s.config.MediaLimit || (in.Body == "" && len(in.MediaIDs) == 0) || (in.Visibility != "PUBLIC" && in.Visibility != "FOLLOWERS" && in.Visibility != "SPACE") || (in.Context != "PERSONAL" && in.Context != "EXPERIENCE_PUBLIC" && in.Context != "EVENT_SPACE") || ((in.Context == "PERSONAL") != (in.ExperienceID == nil)) {
		return nil, ErrContent
	}
	if (in.Context == "EVENT_SPACE") != (in.Visibility == "SPACE") {
		return nil, ErrContent
	}
	if in.ExperienceID != nil && !id(*in.ExperienceID).Valid {
		return nil, identity.ErrInvalid
	}
	seen := map[string]bool{}
	for _, aid := range in.MediaIDs {
		if !id(aid).Valid || seen[aid] {
			return nil, ErrContent
		}
		seen[aid] = true
	}
	var guard func(context.Context, pgx.Tx, *dbgen.Queries) error
	if in.Context == "EVENT_SPACE" {
		guard = spaceGuard(a, *in.ExperienceID, true)
	}
	return s.runGuarded(ctx, a, key, "post.create", req, in, guard, func(ctx context.Context, tx pgx.Tx, q *dbgen.Queries) (string, error) {
		eid := pgtype.UUID{}
		if in.ExperienceID != nil {
			eid = id(*in.ExperienceID)
			if _, e := q.LockExperience(ctx, eid); e != nil {
				return "", identity.ErrNotFound
			}
			ok, e := q.SocialExperienceEligible(ctx, dbgen.SocialExperienceEligibleParams{Column1: eid, Column2: id(a.UserID), Column3: id(a.UserID)})
			if in.Context == "EVENT_SPACE" {
				ok, e = q.SpaceWrite(ctx, dbgen.SpaceWriteParams{Column1: eid, Column2: id(a.UserID)})
			}
			if e != nil {
				return "", e
			}
			if !ok {
				return "", identity.ErrNotFound
			}
		}
		pid := newID()
		if e := q.SocialInsertPost(ctx, dbgen.SocialInsertPostParams{ID: pid, AuthorUserID: id(a.UserID), ExperienceID: eid, Context: in.Context, Visibility: in.Visibility, Body: in.Body}); e != nil {
			return "", e
		}
		for i, aid := range in.MediaIDs {
			u, e := q.LockFlowAsset(ctx, id(aid))
			if e != nil {
				return "", identity.ErrNotFound
			}
			if u.Purpose != "SOCIAL" || u.OwnerUserID != id(a.UserID) || u.Status != "READY" {
				return "", media.ErrOwnership
			}
			if e = q.SocialBindMedia(ctx, dbgen.SocialBindMediaParams{PostID: pid, AssetID: u.ID, Position: int32(i)}); e != nil {
				return "", ErrContent
			}
		}
		return str(pid), emit(ctx, q, a.UserID, str(pid), "social.post.created", req, map[string]any{"context": in.Context, "visibility": in.Visibility})
	})
}
func loadPost(ctx context.Context, q *dbgen.Queries, pid, user string) (map[string]any, error) {
	return document(q.SocialPost(ctx, dbgen.SocialPostParams{Column1: id(pid), Column2: id(user)}))
}
func (s *Service) Post(ctx context.Context, a *identity.Session, pid string) (map[string]any, error) {
	if a == nil {
		return nil, identity.ErrUnauthorized
	}
	if !id(pid).Valid {
		return nil, identity.ErrInvalid
	}
	ctx, c := context.WithTimeout(ctx, 3*time.Second)
	defer c()
	out, e := loadPost(ctx, dbgen.New(s.pool), pid, a.UserID)
	if e == nil {
		s.decorate(out, a)
	}
	return out, e
}
func (s *Service) Profile(ctx context.Context, a *identity.Session, uid string) (map[string]any, error) {
	if a == nil {
		return nil, identity.ErrUnauthorized
	}
	if !id(uid).Valid {
		return nil, identity.ErrInvalid
	}
	ctx, c := context.WithTimeout(ctx, 3*time.Second)
	defer c()
	out, e := document(dbgen.New(s.pool).SocialProfile(ctx, dbgen.SocialProfileParams{Profile: id(uid), Viewer: id(a.UserID)}))
	if e == nil {
		now := time.Now().UTC()
		out["as_of"] = now
		out["valid_until"] = now.Add(30 * time.Second)
	}
	return out, e
}
func (s *Service) PostAction(ctx context.Context, a *identity.Session, pid, key, action, body, expected, req string) (map[string]any, error) {
	if !id(pid).Valid {
		return nil, identity.ErrInvalid
	}
	body = strings.TrimSpace(body)
	if (action == "edit" && (utf8.RuneCountInString(body) > s.config.BodyLimit || !utf8.ValidString(body))) || (action == "comment" && (body == "" || utf8.RuneCountInString(body) > 1000 || !utf8.ValidString(body))) {
		return nil, ErrContent
	}
	if action == "edit" && expected == "" {
		return nil, ErrPrecondition
	}
	return s.runGuarded(ctx, a, key, "post."+action, req, []string{pid, body, expected}, postSpaceGuard(a, pid, action != "delete"), func(ctx context.Context, tx pgx.Tx, q *dbgen.Queries) (string, error) {
		// Read owner before pair/post locks; immutable authorship prevents lock inversion.
		d, e := loadPost(ctx, q, pid, a.UserID)
		if e != nil && action != "delete" {
			return "", e
		}
		var owner string
		if d != nil {
			owner = d["author"].(map[string]any)["user_id"].(string)
		} else {
			p, e := q.SocialLockPost(ctx, id(pid))
			if e != nil || p.AuthorUserID != id(a.UserID) {
				return "", identity.ErrNotFound
			}
			owner = a.UserID
		}
		if e := q.SocialPairLock(ctx, dbgen.SocialPairLockParams{Column1: a.UserID, Column2: owner}); e != nil {
			return "", e
		}
		p, e := q.SocialLockPost(ctx, id(pid))
		if e != nil {
			return "", identity.ErrNotFound
		}
		if action == "delete" {
			if p.AuthorUserID != id(a.UserID) {
				return "", identity.ErrNotFound
			}
			if p.DeletedAt.Valid {
				return pid, nil
			}
			if e = q.SocialDeletePost(ctx, p.ID); e != nil {
				return "", e
			}
			return pid, emit(ctx, q, a.UserID, pid, "social.post.deleted", req, map[string]any{})
		}
		if _, e = loadPost(ctx, q, pid, a.UserID); e != nil {
			return "", e
		}
		resource := pid
		event := "social.post." + action
		changed := int64(1)
		switch action {
		case "edit":
			if p.AuthorUserID != id(a.UserID) {
				return "", identity.ErrNotFound
			}
			if expected != `"`+strconv64(p.Version)+`"` {
				return "", ErrVersion
			}
			if time.Since(p.CreatedAt.Time) > time.Duration(s.config.EditHours)*time.Hour {
				return "", ErrContent
			}
			if body == "" {
				if len(d["media"].([]any)) == 0 {
					return "", ErrContent
				}
			}
			e = q.SocialEditPost(ctx, dbgen.SocialEditPostParams{ID: p.ID, Body: body})
			event = "social.post.edited"
		case "like":
			changed, e = q.SocialLike(ctx, dbgen.SocialLikeParams{PostID: p.ID, UserID: id(a.UserID)})
			event = "social.post.liked"
		case "unlike":
			changed, e = q.SocialUnlike(ctx, dbgen.SocialUnlikeParams{PostID: p.ID, UserID: id(a.UserID)})
			event = "social.post.unliked"
		case "comment":
			cid := newID()
			resource = str(cid)
			e = q.SocialComment(ctx, dbgen.SocialCommentParams{ID: cid, PostID: p.ID, AuthorUserID: id(a.UserID), Body: body})
			event = "social.comment.created"
		default:
			return "", identity.ErrInvalid
		}
		if e != nil {
			return "", e
		}
		if changed == 0 {
			return resource, nil
		}
		return resource, emit(ctx, q, a.UserID, resource, event, req, map[string]any{"post_id": pid})
	})
}
func strconv64(n int64) string { return fmt.Sprintf("%d", n) }
