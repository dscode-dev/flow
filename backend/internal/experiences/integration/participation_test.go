//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"flow.local/backend/internal/experiences"
	"flow.local/backend/internal/participation"
	"github.com/google/uuid"
)

func pkey() map[string]string               { return map[string]string{"Idempotency-Key": uuid.NewString()} }
func pbase(e experiences.Experience) string { return "/v1/experiences/" + e.ID }
func psummary(t *testing.T, r result) participation.Summary {
	t.Helper()
	var out participation.Summary
	if err := json.Unmarshal(r.raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}
func pinvite(t *testing.T, r result) participation.Invitation {
	t.Helper()
	var out participation.Invitation
	if err := json.Unmarshal(r.raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}
func pconfig(t *testing.T, h *harness, a actor, e experiences.Experience, mode string, capacity int) {
	t.Helper()
	r := h.call(t, "GET", pbase(e)+"/participation-settings", a, nil, nil, 200)
	h.call(t, "PUT", pbase(e)+"/participation-settings", a, map[string]any{"mode": mode, "capacity": capacity}, map[string]string{"If-Match": r.header.Get("ETag")}, 200)
}

// Concurrent requests deliberately do not call testing.Fatal from worker goroutines.
func raceParticipation(h *harness, paths []string, actors []actor) []int {
	start := make(chan struct{})
	codes := make([]int, len(paths))
	var wg sync.WaitGroup
	for index, path := range paths {
		wg.Add(1)
		go func(index int, path string) {
			defer wg.Done()
			<-start
			req, err := http.NewRequest("POST", h.server.URL+path, strings.NewReader(`{}`))
			if err != nil {
				codes[index] = -1
				return
			}
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", "Bearer "+actors[index].token)
			req.Header.Set("Idempotency-Key", uuid.NewString())
			r, err := h.server.Client().Do(req)
			if err != nil {
				codes[index] = -1
				return
			}
			defer r.Body.Close()
			_, _ = io.Copy(io.Discard, r.Body)
			codes[index] = r.StatusCode
		}(index, path)
	}
	close(start)
	wg.Wait()
	return codes
}
func TestParticipationSeatsApprovalAndAtomicity(t *testing.T) {
	h := newHarness(t)
	owner, a, b := user(t, true), user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	pconfig(t, h, owner, e, "FREE", 1)
	first := psummary(t, h.call(t, "PUT", pbase(e)+"/interest", a, struct{}{}, pkey(), 200))
	if !first.Interested || first.State != "NONE" || first.ConfirmedCount != 0 {
		t.Fatal("interest consumed a seat")
	}
	path := pbase(e) + "/participation/confirm"
	codes := raceParticipation(h, []string{path, path}, []actor{a, b})
	if codes[0]+codes[1] != 609 || codes[0] != 200 && codes[1] != 200 {
		t.Fatal("last seat", codes)
	}
	winner, loser := a, b
	if codes[1] == 200 {
		winner, loser = b, a
	}
	key := pkey()
	r := h.call(t, "POST", path, winner, struct{}{}, key, 200)
	repeat := h.call(t, "POST", path, winner, struct{}{}, key, 200)
	if !sameJSON(r.raw, repeat.raw) {
		t.Fatal("receipt replay")
	}
	h.call(t, "POST", pbase(e)+"/participation/cancel", winner, struct{}{}, key, 409)
	h.call(t, "POST", pbase(e)+"/participation/cancel", winner, struct{}{}, pkey(), 200)
	h.call(t, "POST", pbase(e)+"/participation/cancel", winner, struct{}{}, pkey(), 200)
	current := psummary(t, h.call(t, "POST", path, loser, struct{}{}, pkey(), 200))
	if current.ConfirmedCount != 1 {
		t.Fatal("seat not released")
	}
	h.call(t, "POST", path, owner, struct{}{}, pkey(), 409)
	var confirmed int
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM participation.members WHERE experience_id=$1 AND state='CONFIRMED'", e.ID).Scan(&confirmed); err != nil || confirmed != 1 {
		t.Fatal("seat consistency", err)
	}
	// PostgreSQL itself refuses an overbooking writer that bypasses the Go policy.
	if _, err := pool.Exec(context.Background(), "UPDATE participation.members SET state='CONFIRMED' WHERE experience_id=$1 AND user_id=$2", e.ID, winner.user); err == nil {
		t.Fatal("database allowed overbooking")
	}
	pconfig(t, h, owner, e, "FREE", 2)
	h.call(t, "POST", path, winner, struct{}{}, pkey(), 200)
	cfg := h.call(t, "GET", pbase(e)+"/participation-settings", owner, nil, nil, 200)
	code(t, h.call(t, "PUT", pbase(e)+"/participation-settings", owner, map[string]any{"mode": "FREE", "capacity": 1}, map[string]string{"If-Match": cfg.header.Get("ETag")}, 409), "capacity_below_confirmed")
	if _, err := pool.Exec(context.Background(), "UPDATE experiences.experiences SET capacity=1 WHERE id=$1", e.ID); err == nil {
		t.Fatal("database allowed capacity reduction")
	}
	h.call(t, "PUT", pbase(e)+"/participation-settings", owner, map[string]any{"mode": "INVITE", "capacity": 3}, map[string]string{"If-Match": "\"1-1\""}, 412)
	// Two pending approvals race for one vacancy; the losing request stays PENDING.
	approval := publish(t, h, owner, create(t, h, owner, fullInput("UNLISTED")))
	pconfig(t, h, owner, approval, "APPROVAL", 1)
	for _, who := range []actor{a, b} {
		h.call(t, "POST", pbase(approval)+"/participation/request", who, struct{}{}, pkey(), 200)
	}
	h.call(t, "POST", pbase(approval)+"/participation/confirm", a, struct{}{}, pkey(), 409)
	codes = raceParticipation(h, []string{pbase(approval) + "/participants/" + a.user + "/approve", pbase(approval) + "/participants/" + b.user + "/approve"}, []actor{owner, owner})
	if codes[0]+codes[1] != 609 {
		t.Fatal("approval race", codes)
	}
	pending := a
	if codes[0] == 200 {
		pending = b
	}
	if v := psummary(t, h.call(t, "GET", pbase(approval)+"/participation", pending, nil, nil, 200)); v.State != "PENDING" {
		t.Fatal("full approval changed pending")
	}
	h.call(t, "POST", pbase(approval)+"/participants/"+pending.user+"/decline", owner, struct{}{}, pkey(), 200)
	h.call(t, "POST", pbase(approval)+"/participation/request", pending, struct{}{}, pkey(), 409)
	// A forced outbox failure rolls back membership, audit and command receipt.
	rollback := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	exec(t, `ALTER TABLE integration.outbox ADD CONSTRAINT participation_test_reject CHECK(event_type<>'participation.confirmed') NOT VALID`)
	h.call(t, "POST", pbase(rollback)+"/participation/confirm", a, struct{}{}, pkey(), 503)
	exec(t, `ALTER TABLE integration.outbox DROP CONSTRAINT participation_test_reject`)
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM participation.members WHERE experience_id=$1", rollback.ID).Scan(&confirmed); err != nil || confirmed != 0 {
		t.Fatal("membership rollback", err)
	}
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM participation.audit WHERE experience_id=$1", rollback.ID).Scan(&confirmed); err != nil || confirmed != 0 {
		t.Fatal("audit rollback", err)
	}
}
func TestParticipationInvitationsPrivacyAndRestrictions(t *testing.T) {
	h := newHarness(t)
	owner, a, b, other := user(t, true), user(t, true), user(t, true), user(t, true)
	e := publish(t, h, owner, create(t, h, owner, fullInput("PRIVATE")))
	pconfig(t, h, owner, e, "INVITE", 1)
	h.call(t, "POST", pbase(e)+"/participants/"+uuid.NewString()+"/unblock", owner, struct{}{}, pkey(), 404)
	h.call(t, "GET", pbase(e), a, nil, nil, 404)
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 404)
	h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": uuid.NewString()}, pkey(), 404)
	key := pkey()
	i := pinvite(t, h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": a.user}, key, 200))
	dup := pinvite(t, h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": a.user}, pkey(), 200))
	if i.ID != dup.ID {
		t.Fatal("duplicate invitation")
	}
	h.call(t, "GET", pbase(e), a, nil, nil, 200)
	h.call(t, "GET", pbase(e), other, nil, nil, 404)
	h.call(t, "GET", pbase(e)+"/participants", a, nil, nil, 404)
	h.call(t, "POST", "/v1/invitations/"+i.ID+"/accept", b, struct{}{}, pkey(), 404)
	h.call(t, "POST", "/v1/invitations/"+i.ID+"/accept", a, struct{}{}, pkey(), 200)
	h.call(t, "POST", "/v1/invitations/"+i.ID+"/revoke", owner, struct{}{}, pkey(), 409)
	ib := pinvite(t, h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": b.user}, pkey(), 200))
	code(t, h.call(t, "POST", "/v1/invitations/"+ib.ID+"/accept", b, struct{}{}, pkey(), 409), "capacity_full")
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/remove", owner, struct{}{}, pkey(), 200)
	h.call(t, "GET", pbase(e), a, nil, nil, 404)
	h.call(t, "POST", "/v1/invitations/"+ib.ID+"/accept", b, struct{}{}, pkey(), 200)
	h.call(t, "POST", pbase(e)+"/participants/"+b.user+"/block", owner, struct{}{}, pkey(), 200)
	h.call(t, "GET", pbase(e), b, nil, nil, 404)
	h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": b.user}, pkey(), 404)
	h.call(t, "POST", pbase(e)+"/participants/"+b.user+"/unblock", owner, struct{}{}, pkey(), 200)
	h.call(t, "GET", pbase(e), b, nil, nil, 404)
	renewed := pinvite(t, h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": b.user}, pkey(), 200))
	if renewed.ID == ib.ID {
		t.Fatal("renewed invite reused terminal id")
	}
	h.call(t, "POST", "/v1/invitations/"+ib.ID+"/accept", b, struct{}{}, pkey(), 404)
	h.call(t, "POST", "/v1/invitations/"+renewed.ID+"/decline", b, struct{}{}, pkey(), 200)
	h.call(t, "GET", pbase(e), b, nil, nil, 404)
	expired := pinvite(t, h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": b.user}, pkey(), 200))
	exec(t, "UPDATE participation.invitations SET expires_at=now()-interval '1 second' WHERE id=$1", expired.ID)
	h.call(t, "POST", "/v1/invitations/"+expired.ID+"/accept", b, struct{}{}, pkey(), 404)
	exec(t, "UPDATE identity.users SET status='suspended' WHERE id=$1", other.user)
	h.call(t, "POST", pbase(e)+"/invitations", owner, map[string]any{"user_id": other.user}, pkey(), 404)
	h.call(t, "GET", "/v1/me/agenda", other, nil, nil, 403)
	// Contextual block removes all public discovery/detail/media entry points.
	raw := imageBytes(t, 42)
	uploaded := initUpload(t, h, owner, raw)
	if status := upload(t, uploaded.Upload, raw, nil); status >= 400 {
		t.Fatal("cover upload")
	}
	h.call(t, "POST", "/v1/media/uploads/"+uploaded.MediaID+"/confirm", owner, struct{}{}, nil, 200)
	input := fullInput("PUBLIC")
	input.CoverMediaID = &uploaded.MediaID
	pub := publish(t, h, owner, create(t, h, owner, input))
	fr := h.call(t, "GET", "/v1/flows/"+pub.ID, a, nil, nil, 200)
	var flow experiences.FlowItem
	if json.Unmarshal(fr.raw, &flow) != nil {
		t.Fatal("flow before block")
	}
	h.call(t, "GET", "/"+flow.ImageURL, a, nil, nil, 200)
	h.call(t, "POST", pbase(pub)+"/participants/"+a.user+"/block", owner, struct{}{}, pkey(), 200)
	h.call(t, "GET", "/"+flow.ImageURL, a, nil, nil, 404)
	for _, path := range []string{pbase(pub), pbase(pub) + "/cover", pbase(pub) + "/participation", "/v1/flows/" + pub.ID} {
		h.call(t, "GET", path, a, nil, nil, 404)
	}
	for _, path := range []string{"/v1/home", "/v1/explore/experiences", "/v1/experiences", "/v1/flows", "/v1/radar/experiences?bbox=-35,-9,-34,-7&zoom=8"} {
		r := h.call(t, "GET", path, a, nil, nil, 200)
		if bytes.Contains(r.raw, []byte(pub.ID)) {
			t.Fatal("blocked discovery path", strings.Split(path, "?")[0])
		}
	}
}
func TestParticipationCheckinProtocol(t *testing.T) {
	h := newHarness(t)
	owner, a, b := user(t, true), user(t, true), user(t, true)
	in := fullInput("PUBLIC")
	start := time.Now().UTC().Add(-time.Minute)
	end := start.Add(2 * time.Hour)
	in.StartsAt = &start
	in.EndsAt = &end
	e := publish(t, h, owner, create(t, h, owner, in))
	path := pbase(e)
	h.call(t, "POST", path+"/check-in-credential", b, struct{}{}, nil, 409)
	h.call(t, "POST", path+"/participation/confirm", a, struct{}{}, pkey(), 200)
	issue := func() participation.Credential {
		r := h.call(t, "POST", path+"/check-in-credential", a, struct{}{}, nil, 200)
		var out participation.Credential
		if json.Unmarshal(r.raw, &out) != nil {
			t.Fatal("credential")
		}
		return out
	}
	c := issue()
	if len(c.Code) != 16 || c.ExpiresAt.Sub(c.AsOf) > 2*time.Minute {
		t.Fatal("credential limits")
	}
	body := map[string]string{"code": c.Code}
	h.call(t, "POST", path+"/check-ins/validate", b, body, pkey(), 404)
	key := pkey()
	first := h.call(t, "POST", path+"/check-ins/validate", owner, body, key, 200)
	again := h.call(t, "POST", path+"/check-ins/validate", owner, body, key, 200)
	if !sameJSON(first.raw, again.raw) {
		t.Fatal("checkin idempotency")
	}
	code(t, h.call(t, "POST", path+"/check-ins/validate", owner, body, pkey(), 409), "checkin_code_used")
	if v := psummary(t, h.call(t, "GET", path+"/participation", a, nil, nil, 200)); !v.CheckedIn || v.State != "CONFIRMED" {
		t.Fatal("checkin overwrote attendance")
	}
	h.call(t, "POST", path+"/check-ins/"+a.user+"/revoke", owner, struct{}{}, pkey(), 200)
	old := issue()
	fresh := issue()
	code(t, h.call(t, "POST", path+"/check-ins/validate", owner, map[string]string{"code": old.Code}, pkey(), 422), "checkin_code_invalid")
	exec(t, "UPDATE participation.checkin_credentials SET expires_at=now()-interval '1 second' WHERE experience_id=$1 AND user_id=$2", e.ID, a.user)
	code(t, h.call(t, "POST", path+"/check-ins/validate", owner, map[string]string{"code": fresh.Code}, pkey(), 409), "checkin_code_expired")
	valid := issue()
	h.call(t, "POST", path+"/check-ins/validate", owner, map[string]string{"code": valid.Code}, pkey(), 200)
	h.call(t, "POST", path+"/participation/cancel", a, struct{}{}, pkey(), 200)
	if v := psummary(t, h.call(t, "GET", path+"/participation", a, nil, nil, 200)); v.CheckedIn {
		t.Fatal("cancelled checkin active")
	}
	var n int
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM participation.checkins WHERE experience_id=$1 AND user_id=$2", e.ID, a.user).Scan(&n); err != nil || n != 1 {
		t.Fatal("unique presence", err)
	}
	h.call(t, "POST", path+"/participation/confirm", a, struct{}{}, pkey(), 200)
	valid = issue()
	exec(t, "UPDATE identity.sessions SET revoked_at=now(),revocation_reason='test' WHERE id=$1", a.session)
	h.call(t, "POST", path+"/check-ins/validate", owner, map[string]string{"code": valid.Code}, pkey(), 409)
	// Identity retention must not be blocked by an expired ephemeral credential.
	exec(t, "DELETE FROM identity.access_credentials WHERE session_id=$1", a.session)
	exec(t, "DELETE FROM identity.sessions WHERE id=$1", a.session)
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM participation.checkin_credentials WHERE experience_id=$1 AND user_id=$2", e.ID, a.user).Scan(&n); err != nil || n != 0 {
		t.Fatal("session credential cascade", err)
	}
	future := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	h.call(t, "POST", pbase(future)+"/participation/confirm", b, struct{}{}, pkey(), 200)
	h.call(t, "POST", pbase(future)+"/check-in-credential", b, struct{}{}, nil, 409)
	current := experience(t, h.call(t, "GET", path, owner, nil, nil, 200))
	h.call(t, "POST", path+"/cancel", owner, struct{}{}, match(current), 200)
	h.call(t, "POST", path+"/participation/confirm", b, struct{}{}, pkey(), 409)
	h.call(t, "POST", path+"/check-ins/validate", owner, body, pkey(), 409)
}
func TestParticipationAgendaAuditAndPagination(t *testing.T) {
	h := newHarness(t)
	owner, a, b := user(t, true), user(t, true), user(t, true)
	var all []experiences.Experience
	for i := range 3 {
		in := fullInput("PUBLIC")
		in.Title = fmt.Sprintf("Agenda %d", i)
		e := publish(t, h, owner, create(t, h, owner, in))
		all = append(all, e)
		h.call(t, "PUT", pbase(e)+"/interest", a, struct{}{}, pkey(), 200)
	}
	h.call(t, "POST", pbase(all[0])+"/participation/confirm", a, struct{}{}, pkey(), 200)
	pconfig(t, h, owner, all[1], "APPROVAL", 2)
	h.call(t, "POST", pbase(all[1])+"/participation/request", a, struct{}{}, pkey(), 200)
	private := publish(t, h, owner, create(t, h, owner, fullInput("PRIVATE")))
	i := pinvite(t, h.call(t, "POST", pbase(private)+"/invitations", owner, map[string]any{"user_id": a.user}, pkey(), 200))
	for _, section := range []string{"upcoming", "pending", "invitations"} {
		r := h.call(t, "GET", "/v1/me/agenda?section="+section, a, nil, nil, 200)
		var p participation.Page
		_ = json.Unmarshal(r.raw, &p)
		if len(p.Items) != 1 {
			t.Fatal("agenda section", section, len(p.Items))
		}
	}
	r := h.call(t, "GET", "/v1/me/agenda?section=interests&limit=2", a, nil, nil, 200)
	var p participation.Page
	_ = json.Unmarshal(r.raw, &p)
	if len(p.Items) != 2 || p.NextCursor == nil {
		t.Fatal("agenda pagination")
	}
	next := "/v1/me/agenda?section=interests&limit=2&cursor=" + url.QueryEscape(*p.NextCursor)
	r = h.call(t, "GET", next, a, nil, nil, 200)
	var second participation.Page
	_ = json.Unmarshal(r.raw, &second)
	if len(second.Items) != 1 || second.Items[0]["experience_id"] == p.Items[0]["experience_id"] {
		t.Fatal("agenda continuation")
	}
	h.call(t, "GET", next, b, nil, nil, 400)
	h.call(t, "GET", strings.Replace(next, "interests", "upcoming", 1), a, nil, nil, 400)
	h.call(t, "POST", "/v1/invitations/"+i.ID+"/revoke", owner, struct{}{}, pkey(), 200)
	history := h.call(t, "GET", "/v1/me/agenda?section=history", a, nil, nil, 200)
	var hp participation.Page
	_ = json.Unmarshal(history.raw, &hp)
	found := false
	for _, item := range hp.Items {
		if item["experience_id"] == private.ID {
			found = true
			if item["accessible"] != false || item["title"] == private.Title || item["starts_at"] != nil || item["venue_name"] != "" {
				t.Fatal("revoked private data leaked")
			}
		}
	}
	if !found {
		t.Fatal("revoked reference missing")
	}
	current := experience(t, h.call(t, "GET", pbase(all[0]), owner, nil, nil, 200))
	h.call(t, "POST", pbase(all[0])+"/cancel", owner, struct{}{}, match(current), 200)
	history = h.call(t, "GET", "/v1/me/agenda?section=history", a, nil, nil, 200)
	if !bytes.Contains(history.raw, []byte("EXPERIENCE_CANCELLED")) {
		t.Fatal("agenda lifecycle not reflected")
	}
	// Every emitted Participation/Invitation/Checkin fact has its own audit entry.
	var events, audits int
	for _, e := range append(all, private) {
		if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM integration.outbox WHERE aggregate_id=$1 AND event_type NOT LIKE 'experience.%'", e.ID).Scan(&events); err != nil {
			t.Fatal(err)
		}
		if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM participation.audit WHERE experience_id=$1", e.ID).Scan(&audits); err != nil || events != audits {
			t.Fatal("outbox/audit", events, audits, err)
		}
	}
	h.call(t, "GET", "/v1/me/agenda?limit=51", a, nil, nil, 400)
	h.call(t, "GET", "/v1/me/agenda?section=upcoming&section=history", a, nil, nil, 400)
}

func sameJSON(a, b []byte) bool {
	var x, y any
	return json.Unmarshal(a, &x) == nil && json.Unmarshal(b, &y) == nil && reflect.DeepEqual(x, y)
}
