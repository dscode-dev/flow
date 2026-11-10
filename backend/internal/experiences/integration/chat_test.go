//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	identityhttp "flow.local/backend/internal/identity/transport"
	"github.com/go-chi/chi/v5"
	"github.com/santhosh-tekuri/jsonschema/v6"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"flow.local/backend/internal/chat"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
	"flow.local/backend/internal/social"
	"github.com/coder/websocket"
	"github.com/google/uuid"
)

func chatPath(eid string) string { return "/v1/experiences/" + eid + "/space/chat" }
func chatDial(t *testing.T, h *harness, a actor, eid string) *websocket.Conn {
	t.Helper()
	ctx, c := context.WithTimeout(t.Context(), 3*time.Second)
	defer c()
	v, _, e := websocket.Dial(ctx, strings.Replace(h.server.URL, "http:", "ws:", 1)+chatPath(eid)+"/socket", &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": []string{"Bearer " + a.token}}, Subprotocols: []string{"flow.chat.v1"}})
	if e != nil {
		t.Fatal("websocket dial failed", e)
	}
	t.Cleanup(func() { v.CloseNow() })
	return v
}
func chatWrite(t *testing.T, c *websocket.Conn, typ string, p any) {
	t.Helper()
	raw, _ := json.Marshal(map[string]any{"message_id": uuid.NewString(), "type": typ, "version": 1, "sent_at": time.Now().UTC(), "payload": p})
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	if e := c.Write(ctx, websocket.MessageText, raw); e != nil {
		t.Fatal(e)
	}
}

var chatSchemaOnce sync.Once
var chatSchema *jsonschema.Schema
var chatSchemaError error

func chatRead(t *testing.T, c *websocket.Conn, typ string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 4*time.Second)
	defer cancel()
	for {
		_, b, e := c.Read(ctx)
		if e != nil {
			t.Fatal("expected realtime frame", typ, e)
		}
		chatSchemaOnce.Do(func() {
			compiler := jsonschema.NewCompiler()
			compiler.DefaultDraft(jsonschema.Draft2020)
			compiler.AssertFormat()
			chatSchema, chatSchemaError = compiler.Compile("../../../../contracts/realtime/chat.schema.json")
		})
		if chatSchemaError != nil {
			t.Fatal(chatSchemaError)
		}
		value, err := jsonschema.UnmarshalJSON(bytes.NewReader(b))
		if err != nil {
			t.Fatal(err)
		}
		if err = chatSchema.Validate(value); err != nil {
			t.Fatal("realtime schema mismatch", err)
		}
		var f chat.Frame
		if json.Unmarshal(b, &f) != nil {
			t.Fatal("invalid frame")
		}
		if f.Version != 1 {
			t.Fatal("version")
		}
		if f.Type == typ {
			var p map[string]any
			if json.Unmarshal(f.Payload, &p) != nil {
				t.Fatal("invalid payload")
			}
			return p
		}
	}
}
func chatHistory(t *testing.T, h *harness, a actor, eid string) map[string]any {
	t.Helper()
	return smap(t, h.call(t, "GET", chatPath(eid)+"/messages", a, nil, nil, 200))
}
func chatJoin(t *testing.T, h *harness, a actor, eid string, c *websocket.Conn) {
	t.Helper()
	p := chatHistory(t, h, a, eid)
	chatWrite(t, c, "chat.join", map[string]any{"cursor": p["resume_cursor"]})
	chatRead(t, c, "chat.joined")
}
func TestChatWebSocketPersistenceRecoveryAndRevocation(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	first := chatHistory(t, h, a, e.ID)
	ca := chatDial(t, h, a, e.ID)
	co := chatDial(t, h, owner, e.ID)
	chatJoin(t, h, a, e.ID, ca)
	chatJoin(t, h, owner, e.ID, co)
	chatWrite(t, ca, "chat.message.send", map[string]string{"client_message_id": "invalid", "body": "Invalid request"})
	if chatRead(t, ca, "chat.error")["code"] != "invalid_request" {
		t.Fatal("invalid client ID accepted")
	}
	client := uuid.NewString()
	send := map[string]any{"client_message_id": client, "body": "Conversa contextual real"}
	chatWrite(t, ca, "chat.message.send", send)
	ack := chatRead(t, ca, "chat.message.ack")
	if ack["sequence"] != "1" {
		t.Fatal("ordering")
	}
	delivered := chatRead(t, co, "chat.message.created")
	if delivered["id"] != ack["id"] {
		t.Fatal("not persisted frame")
	}
	ca.CloseNow()
	ca = chatDial(t, h, a, e.ID)
	chatJoin(t, h, a, e.ID, ca)
	chatWrite(t, ca, "chat.message.send", send)
	if chatRead(t, ca, "chat.message.ack")["id"] != ack["id"] {
		t.Fatal("lost ACK duplicated message")
	}
	chatWrite(t, ca, "chat.message.send", map[string]any{"client_message_id": client, "body": "Outro texto com o mesmo UUID"})
	if chatRead(t, ca, "chat.error")["code"] != "idempotency_conflict" {
		t.Fatal("client UUID reused with different content")
	}
	recovered := smap(t, h.call(t, "GET", chatPath(e.ID)+"/messages?after="+first["resume_cursor"].(string), owner, nil, nil, 400))
	_ = recovered // cursor is scoped to its user/session
	recovered = smap(t, h.call(t, "GET", chatPath(e.ID)+"/messages?after="+first["resume_cursor"].(string), a, nil, nil, 200))
	if len(recovered["items"].([]any)) != 1 {
		t.Fatal("recovery gap")
	}
	h.call(t, "POST", "/v1/social/reports", owner, social.Report{TargetType: "CHAT_MESSAGE", TargetID: ack["id"].(string), Reason: "SPAM"}, pkey(), 200)
	reports := h.call(t, "GET", spaceBase(e)+"/reports", owner, nil, nil, 200)
	if !strings.Contains(string(reports.raw), ack["id"].(string)) {
		t.Fatal("missing contextual report")
	}
	h.call(t, "DELETE", chatPath(e.ID)+"/messages/"+ack["id"].(string), owner, map[string]string{"reason": "SAFETY"}, nil, 200)
	removed := chatRead(t, co, "chat.message.removed")
	chatHistory(t, h, owner, e.ID)
	if removed["body"] != nil || removed["removed"] != true {
		t.Fatal("removed text leaked")
	}
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/remove", owner, struct{}{}, pkey(), 200)
	chatRead(t, ca, "chat.access.revoked")
	h.call(t, "GET", chatPath(e.ID)+"/messages", a, nil, nil, 404)
}
func TestChatAuthorizationOriginLifecycleAndIsolation(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	for _, visibility := range []string{"PUBLIC", "UNLISTED", "PRIVATE"} {
		e := publish(t, h, owner, create(t, h, owner, fullInput(visibility)))
		h.call(t, "GET", chatPath(e.ID)+"/messages", a, nil, nil, 404)
		for _, headers := range []http.Header{{}, {"Authorization": []string{"Bearer " + owner.token}, "Origin": []string{"https://unapproved.invalid"}}, {"Authorization": []string{"Bearer " + a.token}}} {
			ctx, c := context.WithTimeout(t.Context(), 2*time.Second)
			conn, res, err := websocket.Dial(ctx, strings.Replace(h.server.URL, "http:", "ws:", 1)+chatPath(e.ID)+"/socket", &websocket.DialOptions{HTTPHeader: headers})
			c()
			if err == nil {
				conn.CloseNow()
				t.Fatal("unauthorized socket")
			}
			if res == nil || res.StatusCode < 400 {
				t.Fatal("handshake not denied")
			}
		}
		if visibility == "PRIVATE" {
			invite := pinvite(t, h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]string{"user_id": a.user}, pkey(), 200))
			h.call(t, "GET", chatPath(e.ID), a, nil, nil, 404)
			h.call(t, "POST", "/v1/invitations/"+invite.ID+"/accept", a, struct{}{}, pkey(), 200)
		} else {
			h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
		}
		c := chatDial(t, h, a, e.ID)
		chatJoin(t, h, a, e.ID, c)
		chatWrite(t, c, "chat.message.send", map[string]string{"client_message_id": uuid.NewString(), "body": "Antes do encerramento"})
		chatRead(t, c, "chat.message.ack")
		exec(t, "UPDATE experiences.experiences SET starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour' WHERE id=$1", e.ID)
		chatWrite(t, c, "chat.message.send", map[string]string{"client_message_id": uuid.NewString(), "body": "Depois do encerramento"})
		if chatRead(t, c, "chat.error")["code"] != "space_read_only" {
			t.Fatal("ended chat reopened")
		}
		if len(chatHistory(t, h, a, e.ID)["items"].([]any)) != 1 {
			t.Fatal("historical read")
		}
		c.CloseNow()
	}
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	other := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	c := chatDial(t, h, a, e.ID)
	chatJoin(t, h, a, e.ID, c)
	foreign := chatHistory(t, h, owner, other.ID)["resume_cursor"]
	chatWrite(t, c, "chat.join", map[string]any{"cursor": foreign})
	if chatRead(t, c, "chat.error")["code"] != "invalid_request" {
		t.Fatal("room cursor IDOR")
	}
	exec(t, "UPDATE identity.sessions SET revoked_at=now(),revocation_reason='test' WHERE id=$1", a.session)
	chatRead(t, c, "chat.access.revoked")
}
func TestChatConcurrentSequenceModerationLimitsAndCleanup(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	config, _ := chat.ParseConfig([]byte("chat-test-key-32-byte-placeholder!!"))
	service := chat.New(pool, config)
	principal := &identity.Session{ID: a.session, UserID: a.user}
	var wg sync.WaitGroup
	errors := make(chan error, 8)
	ids := make(chan string, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			d, e := service.Send(t.Context(), principal, e.ID, uuid.NewString(), "Mensagem concorrente", "chat-test")
			if e == nil {
				ids <- d["id"].(string)
			}
			errors <- e
		}()
	}
	wg.Wait()
	close(errors)
	close(ids)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	p := chatHistory(t, h, owner, e.ID)
	if len(p["items"].([]any)) != 8 {
		t.Fatal("message lost")
	}
	first := p["items"].([]any)[0].(map[string]any)
	if first["sequence"] != "8" {
		t.Fatal("non-monotonic order")
	}
	mid := <-ids
	if err := service.Remove(t.Context(), principal, otherID(), mid, "SELF", "test"); err == nil {
		t.Fatal("cross-room removal")
	}
	spaceMod(t, h, owner, e.ID, "MODERATOR", a.user, "GRANT", 200)
	for _, action := range []string{"hide-message", "show-message", "delete-message"} {
		if _, err := social.Operate(context.Background(), pool, "operator-test", "case-pr09", action, mid); err != nil {
			t.Fatal(err)
		}
	}
	config.SendMinute = 1
	limited := chat.New(pool, config)
	if _, err := limited.Send(t.Context(), principal, e.ID, uuid.NewString(), "Flood", "test"); err == nil {
		t.Fatal("rate limit ignored")
	}
	c1 := chatDial(t, h, a, e.ID)
	c2 := chatDial(t, h, a, e.ID)
	c3 := chatDial(t, h, a, e.ID)
	_ = c1
	_ = c2
	_ = c3
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	conn, res, err := websocket.Dial(ctx, strings.Replace(h.server.URL, "http:", "ws:", 1)+chatPath(e.ID)+"/socket", &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": []string{"Bearer " + a.token}}})
	if err == nil {
		conn.CloseNow()
		t.Fatal("connection limit ignored")
	}
	if res.StatusCode != 429 {
		t.Fatal("wrong quota response")
	}
	exec(t, "UPDATE chat.messages SET created_at=now()-interval '91 days' WHERE experience_id=$1", e.ID)
	if err := dbgen.New(pool).ChatCleanup(t.Context()); err != nil {
		t.Fatal(err)
	}
	var count int
	pool.QueryRow(t.Context(), "SELECT count(*) FROM chat.messages WHERE experience_id=$1 AND body IS NOT NULL", e.ID).Scan(&count)
	if count != 0 {
		t.Fatal("retention failed")
	}
}
func otherID() string { return uuid.NewString() }

func TestChatMultipleInstancesShutdownAndPayload(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	cfg, _ := chat.ParseConfig(bytes.Repeat([]byte{71}, 32))
	cfg.Poll = 40 * time.Millisecond
	auth := identityhttp.New(identity.NewService(t.Context(), pool, identity.Config{HMACKey: bytes.Repeat([]byte{71}, 32), OriginMinute: 1000}))
	manager := chat.NewHandler(chat.New(pool, cfg), auth)
	router := chi.NewRouter()
	manager.Register(router)
	second := httptest.NewServer(router)
	defer second.Close()
	defer manager.Shutdown()
	peer := &harness{server: second}
	c1 := chatDial(t, h, a, e.ID)
	c2 := chatDial(t, peer, a, e.ID)
	chatJoin(t, h, a, e.ID, c1)
	chatJoin(t, h, a, e.ID, c2)
	chatWrite(t, c1, "chat.message.send", map[string]string{"client_message_id": uuid.NewString(), "body": "Entre instâncias"})
	chatRead(t, c1, "chat.message.ack")
	chatRead(t, c2, "chat.message.created")
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/remove", owner, struct{}{}, pkey(), 200)
	chatRead(t, c1, "chat.access.revoked")
	chatRead(t, c2, "chat.access.revoked")
	oversized := chatDial(t, peer, owner, e.ID)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	_ = oversized.Write(ctx, websocket.MessageText, []byte(strings.Repeat("x", cfg.PayloadLimit+1)))
	if _, _, err := oversized.Read(ctx); err == nil {
		t.Fatal("oversized payload accepted")
	}
	active := chatDial(t, peer, owner, e.ID)
	manager.Shutdown()
	if _, _, err := active.Read(ctx); err == nil {
		t.Fatal("socket survived shutdown")
	}
	deadline := time.Now().Add(2 * time.Second)
	for manager.Active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if manager.Active.Load() != 0 {
		t.Fatal("connection leaked")
	}
}

func TestChatStoredContractsAndRevocationRace(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	cfg, _ := chat.ParseConfig(bytes.Repeat([]byte{71}, 32))
	s := chat.New(pool, cfg)
	principal := &identity.Session{ID: a.session, UserID: a.user}
	first, err := s.Send(t.Context(), principal, e.ID, uuid.NewString(), "Fato persistido", "test")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Remove(t.Context(), principal, e.ID, first["id"].(string), "SELF", "test"); err != nil {
		t.Fatal(err)
	}
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.AssertFormat()
	schema, err := compiler.Compile("../../../../contracts/events/chat-payload.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(t.Context(), "SELECT payload FROM integration.outbox WHERE aggregate_id=$1 AND event_type LIKE 'chat.%'", e.ID)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for rows.Next() {
		var raw []byte
		if err = rows.Scan(&raw); err != nil {
			t.Fatal(err)
		}
		value, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
		if err != nil {
			t.Fatal(err)
		}
		if err = schema.Validate(value); err != nil {
			t.Fatal(err)
		}
		n++
	}
	rows.Close()
	if n != 2 {
		t.Fatal("missing atomic events")
	}
	tx, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	var pid int
	if err = tx.QueryRow(t.Context(), "SELECT pg_backend_pid() FROM experiences.experiences WHERE id=$1 FOR UPDATE", e.ID).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := s.Send(t.Context(), principal, e.ID, uuid.NewString(), "Após revogação", "test")
		done <- err
	}()
	waiting := false
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err = pool.QueryRow(t.Context(), "SELECT EXISTS(SELECT FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))", pid).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !waiting {
		t.Fatal("send never reached room lock")
	}
	if _, err = tx.Exec(t.Context(), "UPDATE participation.members SET state='REMOVED',version=version+1 WHERE experience_id=$1 AND user_id=$2", e.ID, a.user); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(t.Context()); err != nil {
		t.Fatal(err)
	}
	select {
	case err = <-done:
		if err == nil || identity.SafeFailure(err).Status != 404 {
			t.Fatal("revoked send persisted", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("send deadlock")
	}
	var count int
	if err = pool.QueryRow(t.Context(), "SELECT count(*) FROM chat.messages WHERE experience_id=$1", e.ID).Scan(&count); err != nil || count != 1 {
		t.Fatal("revoked message stored", err)
	}
}

func TestChatGlobalBlockRevokesAndRedacts(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	participant := chatDial(t, h, a, e.ID)
	organizer := chatDial(t, h, owner, e.ID)
	chatJoin(t, h, a, e.ID, participant)
	chatJoin(t, h, owner, e.ID, organizer)
	chatWrite(t, participant, "chat.message.send", map[string]string{"client_message_id": uuid.NewString(), "body": "Somente antes do bloqueio"})
	chatRead(t, participant, "chat.message.ack")
	chatRead(t, organizer, "chat.message.created")
	h.call(t, "PUT", "/v1/social/profiles/"+a.user+"/block", owner, struct{}{}, pkey(), 200)
	chatRead(t, participant, "chat.access.revoked")
	chatRead(t, organizer, "chat.reset")
	page := chatHistory(t, h, owner, e.ID)
	m := page["items"].([]any)[0].(map[string]any)
	if m["removed"] != true || m["body"] != nil || m["author"] != nil {
		t.Fatal("blocked author leaked")
	}
}

// Gate server writes after the upgrade to model a TCP consumer that stops
// draining. The deadline must close the socket and preserve persisted history.
type chatSlowConn struct {
	net.Conn
	gate *atomic.Bool
	stop chan struct{}
	once sync.Once
}

func (c *chatSlowConn) Write(b []byte) (int, error) {
	if c.gate.Load() {
		<-c.stop
		return 0, net.ErrClosed
	}
	return c.Conn.Write(b)
}
func (c *chatSlowConn) Close() error { c.once.Do(func() { close(c.stop) }); return c.Conn.Close() }

type chatSlowListener struct {
	net.Listener
	gate *atomic.Bool
}

func (l chatSlowListener) Accept() (net.Conn, error) {
	c, e := l.Listener.Accept()
	if e != nil {
		return nil, e
	}
	return &chatSlowConn{Conn: c, gate: l.gate, stop: make(chan struct{})}, nil
}
func TestChatSlowConsumerTimesOut(t *testing.T) {
	h := newHarness(t)
	owner := user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	cfg, _ := chat.ParseConfig(bytes.Repeat([]byte{71}, 32))
	cfg.Poll = 40 * time.Millisecond
	service := chat.New(pool, cfg)
	auth := identityhttp.New(identity.NewService(t.Context(), pool, identity.Config{HMACKey: bytes.Repeat([]byte{71}, 32), OriginMinute: 1000}))
	manager := chat.NewHandler(service, auth)
	defer manager.Shutdown()
	router := chi.NewRouter()
	manager.Register(router)
	var gate atomic.Bool
	server := httptest.NewUnstartedServer(router)
	server.Listener = chatSlowListener{server.Listener, &gate}
	server.Start()
	defer server.Close()
	slow := chatDial(t, &harness{server: server}, owner, e.ID)
	chatJoin(t, h, owner, e.ID, slow)
	gate.Store(true)
	principal := &identity.Session{ID: owner.session, UserID: owner.user}
	if _, err := service.Send(t.Context(), principal, e.ID, uuid.NewString(), "Persistida mesmo sem consumidor", "test-slow"); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for manager.Active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if manager.Active.Load() != 0 || manager.Errors.Load() == 0 {
		t.Fatal("slow consumer did not release bounded writer")
	}
	if len(chatHistory(t, h, owner, e.ID)["items"].([]any)) != 1 {
		t.Fatal("backpressure lost persisted message")
	}
}
