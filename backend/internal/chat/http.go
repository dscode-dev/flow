package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"flow.local/backend/internal/platform/httpapi"
	"flow.local/backend/internal/social"
	"github.com/coder/websocket"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type Frame struct {
	MessageID   string          `json:"message_id"`
	Type        string          `json:"type"`
	Version     int             `json:"version"`
	SentAt      time.Time       `json:"sent_at"`
	Correlation string          `json:"correlation_id,omitempty"`
	Payload     json.RawMessage `json:"payload"`
}

func frame(typ, correlation string, p any) Frame {
	b, _ := json.Marshal(p)
	return Frame{uuid.NewString(), typ, 1, time.Now().UTC(), correlation, b}
}

type Handler struct {
	Service                  *Service
	Auth                     *identityhttp.Handler
	ctx                      context.Context
	cancel                   context.CancelFunc
	mu                       sync.Mutex
	conns                    map[*websocket.Conn]bool
	closed                   bool
	Active, Errors, Accepted atomic.Int64
}

func NewHandler(s *Service, a *identityhttp.Handler) *Handler {
	ctx, c := context.WithCancel(context.Background())
	return &Handler{Service: s, Auth: a, ctx: ctx, cancel: c, conns: map[*websocket.Conn]bool{}}
}
func (h *Handler) Shutdown() {
	h.mu.Lock()
	h.closed = true
	h.cancel()
	for c := range h.conns {
		c.CloseNow()
	}
	h.mu.Unlock()
}
func (h *Handler) Register(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(h.Auth.Limited, h.Auth.Protected)
		r.Get("/v1/experiences/{experienceId}/space/chat", func(w http.ResponseWriter, r *http.Request) {
			p, e := h.Service.History(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), "", "", 1)
			if e == nil {
				e = audit(r.Context(), dbgen.New(h.Service.Pool), identityhttp.Session(r).UserID, chi.URLParam(r, "experienceId"), "chat.summary.read", httpapi.RequestID(r.Context()), nil)
			}
			social.Respond(w, map[string]any{"capabilities": p.Snapshot, "resume_cursor": p.Resume, "body_limit": h.Service.Config.BodyLimit}, e, r)
		})
		r.Get("/v1/experiences/{experienceId}/space/chat/messages", func(w http.ResponseWriter, r *http.Request) {
			q := r.URL.Query()
			for k, v := range q {
				if len(v) != 1 || (k != "cursor" && k != "after" && k != "limit") {
					social.Respond(w, nil, identity.ErrInvalid, r)
					return
				}
			}
			copy := r.Clone(r.Context())
			u := *r.URL
			copy.URL = &u
			v := copy.URL.Query()
			v.Del("after")
			copy.URL.RawQuery = v.Encode()
			cursor, n, e := social.PageQuery(copy)
			if e != nil {
				social.Respond(w, nil, e, r)
				return
			}
			out, e := h.Service.History(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), cursor, q.Get("after"), n)
			if e == nil {
				e = audit(r.Context(), dbgen.New(h.Service.Pool), identityhttp.Session(r).UserID, chi.URLParam(r, "experienceId"), "chat.history.read", httpapi.RequestID(r.Context()), nil)
			}
			social.Respond(w, out, e, r)
		})
		r.Delete("/v1/experiences/{experienceId}/space/chat/messages/{messageId}", func(w http.ResponseWriter, r *http.Request) {
			var in struct {
				Reason string `json:"reason"`
			}
			if !social.Decode(w, r, &in, "reason") {
				return
			}
			e := h.Service.Remove(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), chi.URLParam(r, "messageId"), in.Reason, httpapi.RequestID(r.Context()))
			social.Respond(w, map[string]string{"id": chi.URLParam(r, "messageId")}, e, r)
		})
		r.Get("/v1/experiences/{experienceId}/space/chat/socket", h.socket)
	})
}
func (h *Handler) allowed(ctx context.Context, token, eid string) (*identity.Session, error) {
	a, e := h.Auth.AuthenticateAccess(ctx, token)
	if e != nil {
		return nil, e
	}
	_, e = h.Service.Snapshot(ctx, a, eid)
	return a, e
}
func (h *Handler) socket(w http.ResponseWriter, r *http.Request) {
	eid := chi.URLParam(r, "experienceId")
	a := identityhttp.Session(r)
	token := strings.SplitN(r.Header.Get("Authorization"), " ", 2)[1]
	if r.URL.RawQuery != "" {
		social.Respond(w, nil, identity.ErrInvalid, r)
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		ok := false
		for _, v := range h.Service.Config.Origins {
			if origin == strings.TrimSpace(v) {
				ok = true
			}
		}
		if !ok {
			social.Respond(w, nil, identity.ErrUnauthorized, r)
			return
		}
	}
	if _, e := h.Service.Snapshot(r.Context(), a, eid); e != nil {
		social.Respond(w, nil, e, r)
		return
	}
	lease := uuid.NewString()
	e := database.InTransaction(r.Context(), h.Service.Pool, func(tx pgx.Tx) error {
		q := dbgen.New(tx)
		if e := q.IdentityAdvisoryLock(r.Context(), "chat:"+a.UserID); e != nil {
			return e
		}
		if e := q.IdentityAdvisoryLock(r.Context(), "chatroom:"+eid); e != nil {
			return e
		}
		n, e := q.ChatUserConnections(r.Context(), id(a.UserID))
		if e != nil {
			return e
		}
		total, e := q.ChatConnectionCount(r.Context(), dbgen.ChatConnectionCountParams{UserID: id(a.UserID), ExperienceID: id(eid)})
		if e != nil {
			return e
		}
		if int(n) >= h.Service.Config.UserConnections || int(total) >= h.Service.Config.RoomConnections {
			return identity.ErrRate
		}
		return q.ChatLease(r.Context(), dbgen.ChatLeaseParams{ID: id(lease), UserID: id(a.UserID), SessionID: id(a.ID), ExperienceID: id(eid)})
	})
	if e != nil {
		social.Respond(w, nil, e, r)
		return
	}
	defer func() {
		ctx, c := context.WithTimeout(context.Background(), time.Second)
		defer c()
		_ = dbgen.New(h.Service.Pool).ChatDisconnect(ctx, id(lease))
	}()
	h.mu.Lock()
	if h.closed || len(h.conns) >= h.Service.Config.ProcessConnections {
		h.mu.Unlock()
		social.Respond(w, nil, identity.ErrRate, r)
		return
	}
	conn, e := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true, Subprotocols: []string{"flow.chat.v1"}, CompressionMode: websocket.CompressionDisabled})
	if e != nil {
		h.mu.Unlock()
		return
	}
	h.conns[conn] = true
	h.mu.Unlock()
	h.Active.Add(1)
	h.Accepted.Add(1)
	slog.Info("chat connection opened", "active", h.Active.Load(), "accepted", h.Accepted.Load())
	defer func() {
		conn.CloseNow()
		h.mu.Lock()
		delete(h.conns, conn)
		h.mu.Unlock()
		h.Active.Add(-1)
		slog.Info("chat connection closed", "active", h.Active.Load(), "errors", h.Errors.Load())
	}()
	ctx, cancel := context.WithTimeout(h.ctx, h.Service.Config.MaxLifetime)
	defer cancel()
	conn.SetReadLimit(int64(h.Service.Config.PayloadLimit))
	input := make(chan Frame, h.Service.Config.QueueLimit)
	failed := make(chan struct{})
	go func() {
		defer close(failed)
		for {
			typ, b, e := conn.Read(ctx)
			if e != nil {
				if ctx.Err() == nil && websocket.CloseStatus(e) != websocket.StatusNormalClosure && websocket.CloseStatus(e) != websocket.StatusGoingAway {
					h.Errors.Add(1)
				}
				return
			}
			var f Frame
			d := json.NewDecoder(bytes.NewReader(b))
			d.DisallowUnknownFields()
			if typ != websocket.MessageText || d.Decode(&f) != nil || d.Decode(new(any)) != io.EOF || f.Version != 1 || !id(f.MessageID).Valid || f.SentAt.IsZero() {
				return
			}
			select {
			case input <- f:
			case <-ctx.Done():
				return
			default:
				return
			}
		}
	}()

	revoke := func(err error) {
		bounded, c := context.WithTimeout(ctx, time.Second)
		defer c()
		b, _ := json.Marshal(frame("chat.access.revoked", "", map[string]string{"code": identity.SafeFailure(err).Code}))
		_ = conn.Write(bounded, websocket.MessageText, b)
	}
	write := func(f Frame) bool {
		bounded, c := context.WithTimeout(ctx, 2*time.Second)
		defer c()
		if _, e := h.allowed(bounded, token, eid); e != nil {
			revoke(e)
			return false
		}

		// A loaded batch is not an authorization cache. Re-materialize each
		// message at the writer boundary, including author blocks/containment.
		if f.Type == "chat.message.created" || f.Type == "chat.message.removed" || f.Type == "chat.message.ack" {
			var previous map[string]any
			if json.Unmarshal(f.Payload, &previous) != nil {
				return false
			}
			mid, ok := previous["id"].(string)
			if !ok {
				return false
			}
			raw, e := dbgen.New(h.Service.Pool).ChatDocument(bounded, dbgen.ChatDocumentParams{Column1: id(mid), Column2: id(a.UserID)})
			if e != nil {
				return false
			}
			current, e := doc(raw)
			if e != nil {
				revoke(e)
				return false
			}
			if current["experience_id"] != eid {
				return false
			}
			if seq, ok := previous["change_sequence"]; ok {
				current["change_sequence"] = seq
			}
			if current["removed"] == true && f.Type != "chat.message.ack" {
				f.Type = "chat.message.removed"
			}
			f.Payload, _ = json.Marshal(current)
		}
		b, _ := json.Marshal(f)
		if e := conn.Write(bounded, websocket.MessageText, b); e != nil {
			h.Errors.Add(1)
			return false
		}
		return true
	}
	cursor := ""
	joined := false
	frames := 0
	window := time.Now()
	lastLease := time.Now()
	tick := time.NewTicker(h.Service.Config.Poll)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-failed:
			return
		case f := <-input:
			if time.Since(window) > time.Minute {
				frames = 0
				window = time.Now()
			}
			frames++
			if frames > 120 {
				return
			}
			bounded, c := context.WithTimeout(ctx, 3*time.Second)
			_, authErr := h.allowed(bounded, token, eid)
			c()
			if authErr != nil {
				revoke(authErr)
				return
			}
			switch f.Type {
			case "chat.join":
				var p struct {
					Cursor string `json:"cursor"`
				}
				if json.Unmarshal(f.Payload, &p) != nil || p.Cursor == "" {
					return
				}
				if _, e := h.Service.parse(a, eid, "after", p.Cursor); e != nil {
					if !write(frame("chat.error", f.MessageID, map[string]string{"code": "invalid_request"})) {
						return
					}
					continue
				}
				cursor = p.Cursor
				joined = true
				if !write(frame("chat.joined", f.MessageID, map[string]string{"experience_id": eid})) {
					return
				}
			case "chat.leave":
				return
			case "chat.message.send":
				if !joined {
					return
				}
				var p struct {
					ClientID string `json:"client_message_id"`
					Body     string `json:"body"`
				}
				d := json.NewDecoder(bytes.NewReader(f.Payload))
				d.DisallowUnknownFields()
				if d.Decode(&p) != nil {
					return
				}
				bounded, c := context.WithTimeout(ctx, 4*time.Second)
				msg, e := h.Service.Send(bounded, a, eid, p.ClientID, p.Body, httpapi.RequestID(r.Context()))
				c()
				if e != nil {
					err := identity.SafeFailure(e)
					payload := map[string]string{"code": err.Code}
					if id(p.ClientID).Valid {
						payload["client_message_id"] = p.ClientID
					}
					if !write(frame("chat.error", f.MessageID, payload)) {
						return
					}
				} else if !write(frame("chat.message.ack", f.MessageID, msg)) {
					return
				}
			case "chat.ping":
				if !write(frame("chat.pong", f.MessageID, map[string]any{})) {
					return
				}
			default:
				if !write(frame("chat.error", f.MessageID, map[string]string{"code": "invalid_request"})) {
					return
				}
			}
		case <-tick.C:
			bounded, c := context.WithTimeout(ctx, 3*time.Second)
			_, e := h.allowed(bounded, token, eid)
			if e != nil {
				c()
				b, _ := json.Marshal(frame("chat.access.revoked", "", map[string]string{"code": identity.SafeFailure(e).Code}))
				wc, cc := context.WithTimeout(ctx, time.Second)
				_ = conn.Write(wc, websocket.MessageText, b)
				cc()
				return
			}
			if time.Since(lastLease) > 5*time.Second {
				e = dbgen.New(h.Service.Pool).ChatLease(bounded, dbgen.ChatLeaseParams{ID: id(lease), UserID: id(a.UserID), SessionID: id(a.ID), ExperienceID: id(eid)})
				lastLease = time.Now()
				if e != nil {
					c()
					return
				}
			}
			if joined {
				p, e := h.Service.History(bounded, a, eid, "", cursor, 50)
				if e != nil {
					c()
					return
				}
				if p.Reset {
					cursor = p.Resume
					if !write(frame("chat.reset", "", map[string]any{"reason": "policy_changed"})) {
						c()
						return
					}
				} else {
					for _, m := range p.Items {
						typ := "chat.message.created"
						if m["removed"] == true {
							typ = "chat.message.removed"
						}
						if !write(frame(typ, "", m)) {
							c()
							return
						}
					}
					cursor = p.Resume
				}
				if !write(frame("chat.sync", "", map[string]any{"cursor": cursor, "capabilities": p.Snapshot})) {
					c()
					return
				}
			}
			c()
		}
	}
}
