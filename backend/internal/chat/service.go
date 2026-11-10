// Package chat implements contextual text messages. PostgreSQL is authoritative;
// transport notifications never constitute permission or successful persistence.
package chat

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"flow.local/backend/internal/social"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Config struct {
	Key                                                                                                   []byte
	BodyLimit, SendMinute, UserConnections, RoomConnections, ProcessConnections, PayloadLimit, QueueLimit int
	Poll, MaxLifetime                                                                                     time.Duration
	Origins                                                                                               []string
}

func ParseConfig(key []byte) (Config, error) {
	if len(key) < 32 {
		return Config{}, identity.ErrInvalid
	}
	c := Config{Key: key, BodyLimit: 2000, SendMinute: 30, UserConnections: 3, RoomConnections: 200, ProcessConnections: 1000, PayloadLimit: 16384, QueueLimit: 16, Poll: time.Second, MaxLifetime: 10 * time.Minute}
	for k, p := range map[string]*int{"CHAT_BODY_LIMIT": &c.BodyLimit, "CHAT_SEND_MINUTE": &c.SendMinute, "CHAT_USER_CONNECTIONS": &c.UserConnections, "CHAT_ROOM_CONNECTIONS": &c.RoomConnections, "CHAT_PROCESS_CONNECTIONS": &c.ProcessConnections, "CHAT_PAYLOAD_LIMIT": &c.PayloadLimit, "CHAT_QUEUE_LIMIT": &c.QueueLimit} {
		if v := os.Getenv(k); v != "" {
			n, e := strconv.Atoi(v)
			if e != nil || n < 1 || n > 65536 {
				return c, identity.ErrInvalid
			}
			*p = n
		}
	}
	if c.BodyLimit > 3000 || c.PayloadLimit < 4096 || c.PayloadLimit > 65536 || c.UserConnections > 10 || c.QueueLimit < 1 || c.QueueLimit > 64 || c.SendMinute > 120 || c.RoomConnections > 2000 || c.ProcessConnections > 5000 {
		return c, identity.ErrInvalid
	}
	for k, unit := range map[string]time.Duration{"CHAT_MAX_CONNECTION_SECONDS": time.Second, "CHAT_POLL_MS": time.Millisecond} {
		if value := os.Getenv(k); value != "" {
			n, e := strconv.Atoi(value)
			if e != nil {
				return c, identity.ErrInvalid
			}
			duration := time.Duration(n) * unit
			if k == "CHAT_POLL_MS" {
				if duration < 250*time.Millisecond || duration > 2*time.Second {
					return c, identity.ErrInvalid
				}
				c.Poll = duration
			} else {
				if duration < 30*time.Second || duration > 10*time.Minute {
					return c, identity.ErrInvalid
				}
				c.MaxLifetime = duration
			}
		}
	}
	if v := os.Getenv("CHAT_ALLOWED_ORIGINS"); v != "" {
		c.Origins = strings.Split(v, ",")
	}
	return c, nil
}

type Service struct {
	Pool   *pgxpool.Pool
	Config Config
}

func New(p *pgxpool.Pool, c Config) *Service { return &Service{p, c} }
func id(s string) pgtype.UUID                { var u pgtype.UUID; _ = u.Scan(s); return u }
func str(u pgtype.UUID) string               { return uuid.UUID(u.Bytes).String() }
func doc(raw []byte) (map[string]any, error) {
	var d map[string]any
	if json.Unmarshal(raw, &d) != nil || d == nil {
		return nil, identity.ErrNotFound
	}
	return d, nil
}

type Snapshot struct {
	CanRead     bool   `json:"can_read"`
	CanWrite    bool   `json:"can_write"`
	CanModerate bool   `json:"can_moderate"`
	Head        string `json:"head"`
	Policy      string `json:"policy"`
}

func snapshot(ctx context.Context, q *dbgen.Queries, eid, uid string) (Snapshot, error) {
	r, e := q.ChatSnapshot(ctx, dbgen.ChatSnapshotParams{Column1: id(eid), Column2: id(uid)})
	if e != nil {
		return Snapshot{}, e
	}
	if !r.CanRead {
		return Snapshot{}, identity.ErrNotFound
	}
	return Snapshot{r.CanRead, r.CanWrite, r.CanModerate, strconv.FormatInt(r.Head, 10), strconv.FormatInt(r.Policy, 10)}, nil
}
func (s *Service) Snapshot(ctx context.Context, a *identity.Session, eid string) (Snapshot, error) {
	if a == nil {
		return Snapshot{}, identity.ErrUnauthorized
	}
	if !id(eid).Valid {
		return Snapshot{}, identity.ErrInvalid
	}
	return snapshot(ctx, dbgen.New(s.Pool), eid, a.UserID)
}

type cursor struct {
	Room, User, Session, Mode       string
	Sequence, Head, Policy, Expires int64
}

func (s *Service) sign(a *identity.Session, eid, mode string, seq, head, policy int64) string {
	b, _ := json.Marshal(cursor{eid, a.UserID, a.ID, mode, seq, head, policy, time.Now().Add(15 * time.Minute).Unix()})
	m := hmac.New(sha256.New, s.Config.Key)
	m.Write(b)
	return base64.RawURLEncoding.EncodeToString(b) + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
func (s *Service) parse(a *identity.Session, eid, mode, raw string) (cursor, error) {
	var c cursor
	p := strings.Split(raw, ".")
	if len(raw) > 2048 || len(p) != 2 {
		return c, identity.ErrInvalid
	}
	b, e := base64.RawURLEncoding.DecodeString(p[0])
	if e != nil {
		return c, identity.ErrInvalid
	}
	sig, e := base64.RawURLEncoding.DecodeString(p[1])
	m := hmac.New(sha256.New, s.Config.Key)
	m.Write(b)
	if e != nil || !hmac.Equal(sig, m.Sum(nil)) || json.Unmarshal(b, &c) != nil || c.Room != eid || c.User != a.UserID || c.Session != a.ID || c.Mode != mode || c.Sequence < 0 || c.Expires < time.Now().Unix() {
		return c, identity.ErrInvalid
	}
	return c, nil
}

type Page struct {
	BodyLimit int              `json:"body_limit"`
	Items     []map[string]any `json:"items"`
	Next      *string          `json:"next_cursor"`
	Resume    string           `json:"resume_cursor"`
	Snapshot  Snapshot         `json:"capabilities"`
	Reset     bool             `json:"reset"`
}

func (s *Service) History(ctx context.Context, a *identity.Session, eid, before, after string, limit int) (Page, error) {
	out := Page{Items: []map[string]any{}, BodyLimit: s.Config.BodyLimit}
	if limit < 1 || limit > 50 || before != "" && after != "" {
		return out, identity.ErrInvalid
	}
	state, e := s.Snapshot(ctx, a, eid)
	if e != nil {
		return out, e
	}
	head, _ := strconv.ParseInt(state.Head, 10, 64)
	policy, _ := strconv.ParseInt(state.Policy, 10, 64)
	out.Snapshot = state
	out.Resume = s.sign(a, eid, "after", head, head, policy)
	q := dbgen.New(s.Pool)
	if after != "" {
		c, e := s.parse(a, eid, "after", after)
		if e != nil {
			return out, e
		}
		if c.Policy != policy {
			out.Reset = true
			return out, nil
		}
		r, e := q.ChatChanges(ctx, dbgen.ChatChangesParams{Viewer: id(a.UserID), ExperienceID: id(eid), AfterSeq: c.Sequence, Snapshot: head, PageLimit: int32(limit + 1)})
		if e != nil {
			return out, e
		}
		for i, v := range r {
			if i == limit {
				break
			}
			d, e := doc(v.Document)
			if e != nil {
				return out, e
			}
			d["change_sequence"] = strconv.FormatInt(v.Sequence, 10)
			out.Items = append(out.Items, d)
			out.Resume = s.sign(a, eid, "after", v.Sequence, head, policy)
		}
		if len(r) > limit {
			v := out.Resume
			out.Next = &v
		}
		return out, nil
	}
	bound := int64(math.MaxInt64)
	if before != "" {
		c, e := s.parse(a, eid, "before", before)
		if e != nil {
			return out, e
		}
		bound = c.Sequence
		head = c.Head
		if c.Policy != policy {
			out.Reset = true
			return out, nil
		}
	}
	rows, e := q.ChatHistory(ctx, dbgen.ChatHistoryParams{Viewer: id(a.UserID), ExperienceID: id(eid), BeforeSeq: bound, Snapshot: head, PageLimit: int32(limit + 1)})
	if e != nil {
		return out, e
	}
	for i, r := range rows {
		if i == limit {
			v := s.sign(a, eid, "before", rows[i-1].Sequence, head, policy)
			out.Next = &v
			break
		}
		d, e := doc(r.Document)
		if e != nil {
			return out, e
		}
		out.Items = append(out.Items, d)
	}
	return out, nil
}
func audit(ctx context.Context, q *dbgen.Queries, a, resource, action, request string, details map[string]any) error {
	b, _ := json.Marshal(details)
	return q.SocialAudit(ctx, dbgen.SocialAuditParams{ID: id(uuid.NewString()), Actor: a, ResourceID: id(resource), Action: action, RequestID: request, Details: b})
}
func emit(ctx context.Context, q *dbgen.Queries, a, eid, mid, action, req string, seq int64) error {
	if e := audit(ctx, q, a, eid, action, req, map[string]any{"message_id": mid}); e != nil {
		return e
	}
	b, _ := json.Marshal(map[string]any{"resource_id": eid, "message_id": mid, "sequence": strconv.FormatInt(seq, 10)})
	return q.AppendOutbox(ctx, dbgen.AppendOutboxParams{EventID: id(uuid.NewString()), EventType: action, SchemaVersion: 1, AggregateID: id(eid), OccurredAt: pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}, Payload: b})
}
func (s *Service) Send(ctx context.Context, a *identity.Session, eid, client, body, req string) (map[string]any, error) {
	body = strings.TrimSpace(body)
	if a == nil {
		return nil, identity.ErrUnauthorized
	}
	if !id(eid).Valid || !id(client).Valid || !utf8.ValidString(body) || utf8.RuneCountInString(body) < 1 || utf8.RuneCountInString(body) > s.Config.BodyLimit {
		return nil, identity.ErrInvalid
	}
	n, e := dbgen.New(s.Pool).SocialRate(ctx, id(a.UserID))
	if e != nil {
		return nil, e
	}
	if n > int32(s.Config.SendMinute) {
		return nil, identity.ErrRate
	}
	var out map[string]any
	hash := sha256.Sum256([]byte(body))
	e = database.InTransaction(ctx, s.Pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, a); e != nil {
			return e
		}
		q := dbgen.New(tx)
		if _, e := q.LockExperience(ctx, id(eid)); e != nil {
			return identity.ErrNotFound
		}
		state, e := snapshot(ctx, q, eid, a.UserID)
		if e != nil {
			return e
		}
		if !state.CanWrite {
			return social.ErrReadOnly
		}
		existing, e := q.ChatFindClient(ctx, dbgen.ChatFindClientParams{ExperienceID: id(eid), AuthorUserID: id(a.UserID), ClientMessageID: id(client)})
		if e == nil {
			if !hmac.Equal(existing.RequestHash, hash[:]) {
				return social.ErrConflict
			}
			raw, e := q.ChatDocument(ctx, dbgen.ChatDocumentParams{Column1: existing.ID, Column2: id(a.UserID)})
			if e != nil {
				return e
			}
			out, e = doc(raw)
			return e
		}
		if !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
		seq, e := q.ChatNext(ctx, id(eid))
		if e != nil {
			return e
		}
		mid := uuid.NewString()
		if e = q.ChatInsert(ctx, dbgen.ChatInsertParams{ID: id(mid), ExperienceID: id(eid), AuthorUserID: id(a.UserID), ClientMessageID: id(client), RequestHash: hash[:], Body: pgtype.Text{String: body, Valid: true}, Sequence: seq}); e != nil {
			return e
		}
		if e = q.ChatChange(ctx, dbgen.ChatChangeParams{ExperienceID: id(eid), Sequence: seq, MessageID: id(mid)}); e != nil {
			return e
		}
		if e = emit(ctx, q, a.UserID, eid, mid, "chat.message.created", req, seq); e != nil {
			return e
		}
		raw, e := q.ChatDocument(ctx, dbgen.ChatDocumentParams{Column1: id(mid), Column2: id(a.UserID)})
		if e != nil {
			return e
		}
		out, e = doc(raw)
		return e
	})
	return out, e
}
func (s *Service) Remove(ctx context.Context, a *identity.Session, eid, mid, reason, req string) error {
	if a == nil {
		return identity.ErrUnauthorized
	}
	if !id(eid).Valid || !id(mid).Valid {
		return identity.ErrInvalid
	}
	switch reason {
	case "SELF", "ABUSE", "SPAM", "PRIVACY", "SAFETY", "OTHER":
	default:
		return identity.ErrInvalid
	}
	return database.InTransaction(ctx, s.Pool, func(tx pgx.Tx) error {
		if e := identity.RequireCreator(ctx, tx, a); e != nil {
			return e
		}
		q := dbgen.New(tx)
		if _, e := q.LockExperience(ctx, id(eid)); e != nil {
			return identity.ErrNotFound
		}
		m, e := q.ChatLockMessage(ctx, id(mid))
		if e != nil || m.ExperienceID != id(eid) {
			return identity.ErrNotFound
		}
		if m.AuthorUserID != id(a.UserID) {
			state, e := snapshot(ctx, q, eid, a.UserID)
			if e != nil {
				return e
			}
			if !state.CanModerate || reason == "SELF" {
				return identity.ErrNotFound
			}
		}
		if m.DeletedAt.Valid {
			return nil
		}
		if e = q.ChatRemove(ctx, m.ID); e != nil {
			return e
		}
		seq, e := q.ChatNext(ctx, id(eid))
		if e != nil {
			return e
		}
		if e = q.ChatChange(ctx, dbgen.ChatChangeParams{ExperienceID: id(eid), Sequence: seq, MessageID: m.ID}); e != nil {
			return e
		}
		if e = audit(ctx, q, a.UserID, eid, "chat.moderation.reason", req, map[string]any{"message_id": mid, "reason": reason}); e != nil {
			return e
		}
		return emit(ctx, q, a.UserID, eid, mid, "chat.message.removed", req, seq)
	})
}
