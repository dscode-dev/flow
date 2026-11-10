//go:build integration

package integration

import (
	"bytes"
	"context"
	"flow.local/backend/internal/experiences"
	"flow.local/backend/internal/social"
	"github.com/santhosh-tekuri/jsonschema/v6"
	"io"
	"net/http"
	"net/url"
	"testing"
	"time"
)

func spaceBase(e experiences.Experience) string { return pbase(e) + "/space" }
func spacePost(t *testing.T, h *harness, a actor, eid, body string, want int, assets ...string) string {
	t.Helper()
	if assets == nil {
		assets = []string{}
	}
	r := h.call(t, "POST", "/v1/social/posts", a, social.Input{Context: "EVENT_SPACE", Visibility: "SPACE", ExperienceID: &eid, Body: body, MediaIDs: assets}, pkey(), want)
	if want != 200 {
		return ""
	}
	return smap(t, r)["id"].(string)
}
func spaceMod(t *testing.T, h *harness, a actor, eid, typ, target, action string, want int) {
	t.Helper()
	h.call(t, "POST", "/v1/experiences/"+eid+"/space/moderation", a, social.SpaceModeration{TargetType: typ, TargetID: target, Action: action, Reason: "SAFETY"}, pkey(), want)
}
func TestEventSpaceAccessMatrixAndNoSocialLeak(t *testing.T) {
	h := newHarness(t)
	owner, a, b := user(t, true), user(t, true), user(t, true)
	for _, visibility := range []string{"PUBLIC", "UNLISTED", "PRIVATE"} {
		e := create(t, h, owner, fullInput(visibility))
		summary := smap(t, h.call(t, "GET", spaceBase(e), owner, nil, nil, 200))
		if summary["capabilities"].(map[string]any)["can_read"] != false {
			t.Fatal("draft content")
		}
		spacePost(t, h, owner, e.ID, "Rascunho", 404)
		e = publish(t, h, owner, e)
		want := 200
		if visibility == "PRIVATE" {
			want = 404
		}
		r := h.call(t, "GET", spaceBase(e), a, nil, nil, want)
		if want == 200 {
			preview := smap(t, r)
			if preview["participant_count"] != nil || preview["capabilities"].(map[string]any)["can_read"] != false {
				t.Fatal("public preview leaked")
			}
		}
		h.call(t, "GET", spaceBase(e)+"/feed", a, nil, nil, 404)
		h.call(t, "PUT", pbase(e)+"/interest", a, struct{}{}, pkey(), want)
		h.call(t, "GET", spaceBase(e)+"/participants", a, nil, nil, 404)
		if visibility == "PRIVATE" {
			invite := pinvite(t, h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": a.user}, pkey(), 200))
			h.call(t, "GET", spaceBase(e), a, nil, nil, 404)
			h.call(t, "GET", spaceBase(e)+"/gallery", a, nil, nil, 404)
			h.call(t, "POST", "/v1/invitations/"+invite.ID+"/accept", a, struct{}{}, pkey(), 200)
		} else {
			h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
		}
		pid := spacePost(t, h, a, e.ID, "Conteúdo exclusivo de "+visibility, 200)
		sget(t, h, owner, pid)
		h.call(t, "GET", "/v1/social/posts/"+pid, b, nil, nil, 404)
		for _, path := range []string{"/v1/social/feed", "/v1/social/feed?mode=FOLLOWING", "/v1/social/profiles/" + a.user + "/posts"} {
			result := h.call(t, "GET", path, owner, nil, nil, 200)
			if bytes.Contains(result.raw, []byte(pid)) {
				t.Fatal("context leaked to social", path)
			}
		}
		roster := h.call(t, "GET", spaceBase(e)+"/participants", a, nil, nil, 200)
		if bytes.Contains(roster.raw, []byte("checked_in")) || bytes.Contains(roster.raw, []byte("phone")) {
			t.Fatal("private participation data")
		}
		h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/remove", owner, struct{}{}, pkey(), 200)
		h.call(t, "GET", "/v1/social/posts/"+pid, a, nil, nil, 404)
		h.call(t, "GET", spaceBase(e)+"/feed", a, nil, nil, 404)
		h.call(t, "DELETE", "/v1/social/posts/"+pid, a, struct{}{}, pkey(), 200)
	}
}
func TestEventSpaceModerationRolesAndMemories(t *testing.T) {
	h := newHarness(t)
	owner, a, b := user(t, true), user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	for _, person := range []actor{a, b} {
		h.call(t, "POST", pbase(e)+"/participation/confirm", person, struct{}{}, pkey(), 200)
	}
	pid := spacePost(t, h, b, e.ID, "Momento protegido", 200)
	path := "/v1/social/posts/" + pid
	spaceMod(t, h, a, e.ID, "POST", pid, "HIDE", 404)
	spaceMod(t, h, owner, e.ID, "MODERATOR", a.user, "GRANT", 200)
	spaceMod(t, h, a, e.ID, "POST", pid, "HIDE", 200)
	h.call(t, "GET", path, b, nil, nil, 404)
	hidden := h.call(t, "GET", spaceBase(e)+"/hidden", a, nil, nil, 200)
	if !bytes.Contains(hidden.raw, []byte(pid)) {
		t.Fatal("hidden moderation")
	}
	h.call(t, "GET", spaceBase(e)+"/hidden", b, nil, nil, 404)
	spaceMod(t, h, a, e.ID, "POST", pid, "RESTORE", 200)
	cid := smap(t, h.call(t, "POST", path+"/comments", b, map[string]any{"body": "Comentário contextual"}, pkey(), 200))["id"].(string)
	h.call(t, "POST", "/v1/social/reports", b, social.Report{TargetType: "COMMENT", TargetID: cid, Reason: "SPAM"}, pkey(), 200)
	reports := smap(t, h.call(t, "GET", spaceBase(e)+"/reports", a, nil, nil, 200))
	report := reports["items"].([]any)[0].(map[string]any)
	if _, ok := report["reporter_user_id"]; ok {
		t.Fatal("reporter exposed")
	}
	spaceMod(t, h, a, e.ID, "REPORT", report["id"].(string), "REVIEW", 200)
	spaceMod(t, h, a, e.ID, "COMMENT", cid, "HIDE", 200)
	if sget(t, h, b, pid)["comment_count"] != float64(0) {
		t.Fatal("locally hidden comment counted")
	}
	spaceMod(t, h, a, e.ID, "COMMENT", cid, "RESTORE", 200)
	foreign := spost(t, h, b, "PUBLIC", "Pessoal")
	spaceMod(t, h, a, e.ID, "POST", foreign, "HIDE", 404)
	spaceMod(t, h, a, e.ID, "PARTICIPANT", b.user, "RESTRICT", 200)
	spacePost(t, h, b, e.ID, "Restrito", 409)
	sget(t, h, b, pid)
	spaceMod(t, h, a, e.ID, "PARTICIPANT", b.user, "ALLOW", 200)
	spaceMod(t, h, owner, e.ID, "SPACE", e.ID, "PAUSE", 200)
	h.call(t, "PUT", path+"/like", b, struct{}{}, pkey(), 409)
	spaceMod(t, h, owner, e.ID, "SPACE", e.ID, "RESUME", 200)
	// Removing a moderator revokes the stored role, even after a new confirmation.
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/remove", owner, struct{}{}, pkey(), 200)
	spaceMod(t, h, a, e.ID, "POST", pid, "HIDE", 404)
	var active bool
	pool.QueryRow(context.Background(), "SELECT active FROM event_space.moderators WHERE experience_id=$1 AND user_id=$2", e.ID, a.user).Scan(&active)
	if active {
		t.Fatal("moderator grant survived removal")
	}
	// Derive ENDED from the actual agenda, without a state cron.
	exec(t, "UPDATE experiences.experiences SET starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour' WHERE id=$1", e.ID)
	summary := smap(t, h.call(t, "GET", spaceBase(e), b, nil, nil, 200))
	if summary["phase"] != "ENDED" || summary["capabilities"].(map[string]any)["can_write"] != false {
		t.Fatal("memories phase")
	}
	spacePost(t, h, b, e.ID, "Atrasado", 409)
	h.call(t, "POST", path+"/comments", b, map[string]any{"body": "Tarde"}, pkey(), 409)
	sget(t, h, b, pid)
	e = experience(t, h.call(t, "GET", pbase(e), owner, nil, nil, 200))
	e = experience(t, h.call(t, "POST", pbase(e)+"/archive", owner, struct{}{}, match(e), 200))
	h.call(t, "GET", spaceBase(e)+"/feed", b, nil, nil, 200)
	h.call(t, "DELETE", path+"/comments/"+cid, b, struct{}{}, pkey(), 200)
	var n int
	pool.QueryRow(context.Background(), "SELECT count(*) FROM social.audit WHERE resource_id=$1 AND action LIKE 'eventspace.%'", e.ID).Scan(&n)
	if n < 5 {
		t.Fatal("missing contextual audit")
	}
}
func TestEventSpaceGalleryCapabilitiesAndRevocation(t *testing.T) {
	h := newHarness(t)
	owner, a, b := user(t, true), user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PRIVATE")))
	invite := pinvite(t, h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": a.user}, pkey(), 200))
	h.call(t, "POST", "/v1/invitations/"+invite.ID+"/accept", a, struct{}{}, pkey(), 200)
	asset := socialUpload(t, h, a, "image/png", imageBytes(t, 90))
	pid := spacePost(t, h, a, e.ID, "Memória com imagem", 200, asset.ID)
	spacePost(t, h, a, e.ID, "Segundo registro", 200)
	first := smap(t, h.call(t, "GET", spaceBase(e)+"/feed?limit=1", a, nil, nil, 200))
	next := first["next_cursor"].(string)
	h.call(t, "GET", spaceBase(e)+"/feed?limit=1&cursor="+url.QueryEscape(next), a, nil, nil, 200)
	h.call(t, "GET", spaceBase(e)+"/gallery?limit=1&cursor="+url.QueryEscape(next), a, nil, nil, 400)
	gallery := smap(t, h.call(t, "GET", spaceBase(e)+"/gallery", owner, nil, nil, 200))
	item := gallery["items"].([]any)[0].(map[string]any)
	post := item["post"].(map[string]any)
	link := "/" + post["media"].([]any)[0].(map[string]any)["url"].(string)
	h.call(t, "GET", link, actor{}, nil, nil, 200)
	h.call(t, "GET", link, actor{}, nil, map[string]string{"Range": "bytes=0-31"}, 206)
	h.call(t, "GET", spaceBase(e)+"/gallery", b, nil, nil, 404)
	spaceMod(t, h, owner, e.ID, "POST", pid, "HIDE", 200)
	h.call(t, "GET", link, actor{}, nil, nil, 404)
	h.call(t, "GET", link, actor{}, nil, map[string]string{"Range": "bytes=0-31"}, 404)
	spaceMod(t, h, owner, e.ID, "POST", pid, "RESTORE", 200)
	d := sget(t, h, a, pid)
	link = "/" + d["media"].([]any)[0].(map[string]any)["url"].(string)
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/remove", owner, struct{}{}, pkey(), 200)
	h.call(t, "GET", link, actor{}, nil, nil, 404)
	h.call(t, "GET", link, actor{}, nil, map[string]string{"Range": "bytes=0-31"}, 404)
	h.call(t, "GET", spaceBase(e)+"/gallery", a, nil, nil, 404)
}

// The waiting mutation must re-evaluate membership after acquiring the same
// experience lock used by Participation. No timing guess decides the assertion.
func TestEventSpaceRevocationSerializesMutation(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	pid := spacePost(t, h, owner, e.ID, "Registro do organizador", 200)
	tx, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	var backendPID int
	if err = tx.QueryRow(t.Context(), "SELECT pg_backend_pid() FROM experiences.experiences WHERE id=$1 FOR UPDATE", e.ID).Scan(&backendPID); err != nil {
		t.Fatal(err)
	}
	done := make(chan int, 1)
	req, err := http.NewRequest("PUT", h.server.URL+"/v1/social/posts/"+pid+"/like", bytes.NewReader([]byte("{}")))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+a.token)
	req.Header.Set("Idempotency-Key", pkey()["Idempotency-Key"])
	go func() {
		res, x := h.server.Client().Do(req)
		if x != nil {
			done <- 0
			return
		}
		io.Copy(io.Discard, res.Body)
		res.Body.Close()
		done <- res.StatusCode
	}()
	deadline := time.Now().Add(5 * time.Second)
	waiting := false
	for time.Now().Before(deadline) {
		if err = pool.QueryRow(t.Context(), "SELECT EXISTS(SELECT FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))", backendPID).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !waiting {
		t.Fatal("mutation never reached contextual lock")
	}
	if _, err = tx.Exec(t.Context(), "UPDATE participation.members SET state='REMOVED',version=version+1 WHERE experience_id=$1 AND user_id=$2", e.ID, a.user); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(t.Context()); err != nil {
		t.Fatal(err)
	}
	select {
	case status := <-done:
		if status != 404 {
			t.Fatalf("revoked mutation status=%d", status)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("mutation deadlock")
	}
	var n int
	if err = pool.QueryRow(t.Context(), "SELECT count(*) FROM social.likes WHERE post_id=$1 AND user_id=$2", pid, a.user).Scan(&n); err != nil || n != 0 {
		t.Fatal("revoked mutation persisted", err)
	}
}
func TestEventSpacePendingBlocksHistoricalRevocationAndPlatform(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	// REQUEST mode does not turn a pending request into contextual authorization.
	pconfig(t, h, owner, e, "APPROVAL", 4)
	h.call(t, "POST", pbase(e)+"/participation/request", a, struct{}{}, pkey(), 200)
	h.call(t, "GET", spaceBase(e)+"/feed", a, nil, nil, 404)
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/approve", owner, struct{}{}, pkey(), 200)
	pid := spacePost(t, h, owner, e.ID, "Registro histórico", 200)
	key := pkey()
	h.call(t, "PUT", "/v1/social/posts/"+pid+"/like", a, struct{}{}, key, 200)
	if _, err := social.Operate(t.Context(), pool, "operator-test", "case-pr08", "hide-space", e.ID); err != nil {
		t.Fatal(err)
	}
	h.call(t, "GET", spaceBase(e)+"/feed", a, nil, nil, 404)
	spaceMod(t, h, owner, e.ID, "SPACE", e.ID, "RESUME", 404)
	if _, err := social.Operate(t.Context(), pool, "operator-test", "case-pr08", "show-space", e.ID); err != nil {
		t.Fatal(err)
	}
	sget(t, h, a, pid)
	h.call(t, "PUT", "/v1/social/profiles/"+owner.user+"/block", a, struct{}{}, pkey(), 200)
	h.call(t, "GET", spaceBase(e), a, nil, nil, 404)
	h.call(t, "DELETE", "/v1/social/profiles/"+owner.user+"/block", a, struct{}{}, pkey(), 200)

	exec(t, "UPDATE identity.users SET status='suspended' WHERE id=$1", a.user)
	h.call(t, "GET", spaceBase(e)+"/feed", a, nil, nil, 403)
	exec(t, "UPDATE identity.users SET status='active' WHERE id=$1", a.user)
	sget(t, h, a, pid)
	e = experience(t, h.call(t, "GET", pbase(e), owner, nil, nil, 200))
	e = experience(t, h.call(t, "POST", pbase(e)+"/cancel", owner, struct{}{}, match(e), 200))
	sget(t, h, a, pid)
	spacePost(t, h, a, e.ID, "Após cancelar", 409)
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/remove", owner, map[string]any{"reason": "SAFETY"}, pkey(), 200)
	h.call(t, "PUT", "/v1/social/posts/"+pid+"/like", a, struct{}{}, key, 404)
	h.call(t, "GET", spaceBase(e)+"/feed", a, nil, nil, 404)
}

func TestEventSpaceStoredContracts(t *testing.T) {
	h := newHarness(t)
	owner, a := user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	spaceMod(t, h, owner, e.ID, "MODERATOR", a.user, "GRANT", 200)
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/block", owner, map[string]any{"reason": "SAFETY"}, pkey(), 200)
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.AssertFormat()
	payload, err := compiler.Compile("../../../../contracts/events/event-space-payload.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	envelope, err := compiler.Compile("../../../../contracts/events/envelope.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(t.Context(), "SELECT payload,jsonb_build_object('event_id',event_id,'event_type',event_type,'schema_version',schema_version,'aggregate_id',aggregate_id,'occurred_at',occurred_at,'payload',payload) FROM integration.outbox WHERE aggregate_id=$1 AND event_type LIKE 'eventspace.%'", e.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var p, v []byte
		if err = rows.Scan(&p, &v); err != nil {
			t.Fatal(err)
		}
		pv, x := jsonschema.UnmarshalJSON(bytes.NewReader(p))
		if x != nil {
			t.Fatal(x)
		}
		if x = payload.Validate(pv); x != nil {
			t.Fatal(x)
		}
		ev, x := jsonschema.UnmarshalJSON(bytes.NewReader(v))
		if x != nil {
			t.Fatal(x)
		}
		if x = envelope.Validate(ev); x != nil {
			t.Fatal(x)
		}
		n++
	}
	if rows.Err() != nil || n < 2 {
		t.Fatal("missing atomic role/moderation facts", rows.Err())
	}
	res, err := h.server.Client().Get(h.server.URL + "/__fixture/session")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 404 {
		t.Fatal("fixture exposed outside test bridge")
	}
}
