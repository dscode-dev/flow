//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/database/dbgen"
	"flow.local/backend/internal/social"
	"fmt"
	"github.com/google/uuid"
	"github.com/santhosh-tekuri/jsonschema/v6"
	"io"
	"net/http"
	"net/url"
	"os"
	osexec "os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
)

func smap(t *testing.T, r result) map[string]any {
	t.Helper()
	var d map[string]any
	if e := json.Unmarshal(r.raw, &d); e != nil {
		t.Fatal(e)
	}
	return d
}
func spost(t *testing.T, h *harness, a actor, visibility, body string, mediaIDs ...string) string {
	t.Helper()
	if mediaIDs == nil {
		mediaIDs = []string{}
	}
	d := smap(t, h.call(t, "POST", "/v1/social/posts", a, map[string]any{"context": "PERSONAL", "visibility": visibility, "body": body, "media_ids": mediaIDs}, pkey(), 200))
	return d["id"].(string)
}
func sget(t *testing.T, h *harness, a actor, pid string) map[string]any {
	return smap(t, h.call(t, "GET", "/v1/social/posts/"+pid, a, nil, nil, 200))
}
func srelation(t *testing.T, h *harness, a actor, uid, suffix, method string) {
	h.call(t, method, "/v1/social/profiles/"+uid+"/"+suffix, a, struct{}{}, pkey(), 200)
}
func TestSocialPostsGraphPrivacyAndPagination(t *testing.T) {
	h := newHarness(t)
	a, b, c := user(t, true), user(t, true), user(t, true)
	spost(t, h, a, "PUBLIC", "Registro público")
	private := spost(t, h, a, "FOLLOWERS", "Registro de seguidores")
	h.call(t, "GET", "/v1/social/feed", actor{}, nil, nil, 401)
	h.call(t, "GET", "/v1/social/posts/"+private, b, nil, nil, 404)
	srelation(t, h, b, a.user, "follow", "PUT")
	srelation(t, h, b, a.user, "follow", "PUT")
	d := sget(t, h, b, private)
	if d["body"] != "Registro de seguidores" {
		t.Fatal("followers read")
	}
	page := smap(t, h.call(t, "GET", "/v1/social/feed?mode=FOLLOWING&limit=1", b, nil, nil, 200))
	if len(page["items"].([]any)) != 1 || page["next_cursor"] == nil {
		t.Fatal("cursor first")
	}
	next := page["next_cursor"].(string)
	page2 := smap(t, h.call(t, "GET", "/v1/social/feed?mode=FOLLOWING&limit=1&cursor="+url.QueryEscape(next), b, nil, nil, 200))
	if len(page2["items"].([]any)) != 1 || page["items"].([]any)[0].(map[string]any)["id"] == page2["items"].([]any)[0].(map[string]any)["id"] {
		t.Fatal("cursor duplicate")
	}
	h.call(t, "GET", "/v1/social/feed?mode=DISCOVER&limit=1&cursor="+url.QueryEscape(next), b, nil, nil, 400)
	h.call(t, "GET", "/v1/social/feed?mode=FOLLOWING&limit=1&cursor="+url.QueryEscape(next), c, nil, nil, 400)
	profile := smap(t, h.call(t, "GET", "/v1/social/profiles/"+a.user, b, nil, nil, 200))
	if profile["follower_count"] != float64(1) || profile["post_count"] != float64(2) || !profile["following"].(bool) {
		t.Fatal("real profile counts")
	}
	for _, field := range []string{"phone", "email", "federated_id", "avatar_url", "bio"} {
		if _, ok := profile[field]; ok {
			t.Fatal("private or fictional profile field")
		}
	}
	h.call(t, "GET", "/v1/social/profiles/"+a.user+"/followers", b, nil, nil, 200)
	h.call(t, "PATCH", "/v1/social/posts/"+private, b, map[string]any{"body": "inválido"}, map[string]string{"Idempotency-Key": uuid.NewString(), "If-Match": "\"1\""}, 404)
	headers := map[string]string{"Idempotency-Key": uuid.NewString(), "If-Match": "\"1\""}
	h.call(t, "PATCH", "/v1/social/posts/"+private, a, map[string]any{"body": "Texto editado"}, headers, 200)
	headers["Idempotency-Key"] = uuid.NewString()
	h.call(t, "PATCH", "/v1/social/posts/"+private, a, map[string]any{"body": "Obsoleto"}, headers, 412)
	// Same receipt contains only an opaque ID, never withdrawn content.
	k := pkey()
	input := map[string]any{"context": "PERSONAL", "visibility": "PUBLIC", "body": "Uma intenção", "media_ids": []string{}}
	r1 := h.call(t, "POST", "/v1/social/posts", a, input, k, 200)
	r2 := h.call(t, "POST", "/v1/social/posts", a, input, k, 200)
	if !sameJSON(r1.raw, r2.raw) {
		t.Fatal("receipt")
	}
	input["body"] = "Outra intenção"
	h.call(t, "POST", "/v1/social/posts", a, input, k, 409)
	srelation(t, h, b, a.user, "block", "PUT")
	h.call(t, "GET", "/v1/social/posts/"+private, b, nil, nil, 404)
	h.call(t, "GET", "/v1/social/profiles/"+a.user, b, nil, nil, 404)
	h.call(t, "GET", "/v1/social/profiles/"+b.user, a, nil, nil, 404)
	h.call(t, "PUT", "/v1/social/profiles/"+a.user+"/follow", b, struct{}{}, pkey(), 404)
	page = smap(t, h.call(t, "GET", "/v1/social/feed?mode=FOLLOWING&limit=1&cursor="+url.QueryEscape(next), b, nil, nil, 200))
	if len(page["items"].([]any)) != 0 {
		t.Fatal("cursor block bypass")
	}
	h.call(t, "GET", "/v1/social/blocks", b, nil, nil, 200)
	srelation(t, h, b, a.user, "block", "DELETE")
	h.call(t, "GET", "/v1/social/posts/"+private, b, nil, nil, 404)
	profile = smap(t, h.call(t, "GET", "/v1/social/profiles/"+a.user, b, nil, nil, 200))
	if profile["following"] != false || profile["follower_count"] != float64(0) || profile["post_count"] != float64(2) {
		t.Fatal("unblock restored relationship or leaked follower post")
	}
	h.call(t, "DELETE", "/v1/social/posts/"+private, a, struct{}{}, pkey(), 200)
	h.call(t, "DELETE", "/v1/social/posts/"+private, a, struct{}{}, pkey(), 200)
	h.call(t, "GET", "/v1/social/posts/"+private, a, nil, nil, 404)
}
func TestSocialInteractionsConcurrencyModerationAndAbuse(t *testing.T) {
	h := newHarness(t)
	a, b, c := user(t, true), user(t, true), user(t, true)
	pid := spost(t, h, a, "PUBLIC", "Interações")
	path := "/v1/social/posts/" + pid
	var wg sync.WaitGroup
	statuses := make([]int, 12)
	start := make(chan struct{})
	for i := range statuses {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			r, _ := http.NewRequest("PUT", h.server.URL+path+"/like", strings.NewReader(`{}`))
			r.Header.Set("Authorization", "Bearer "+b.token)
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Idempotency-Key", uuid.NewString())
			response, e := h.server.Client().Do(r)
			if e != nil {
				statuses[i] = -1
				return
			}
			defer response.Body.Close()
			io.Copy(io.Discard, response.Body)
			statuses[i] = response.StatusCode
		}(i)
	}
	close(start)
	wg.Wait()
	for _, s := range statuses {
		if s != 200 {
			t.Fatalf("concurrent like=%d", s)
		}
	}
	if sget(t, h, a, pid)["like_count"] != float64(1) {
		t.Fatal("duplicate like")
	}
	h.call(t, "DELETE", path+"/like", b, struct{}{}, pkey(), 200)
	h.call(t, "DELETE", path+"/like", b, struct{}{}, pkey(), 200)
	cid := smap(t, h.call(t, "POST", path+"/comments", b, map[string]any{"body": "Comentário real"}, pkey(), 200))["id"].(string)
	h.call(t, "DELETE", path+"/comments/"+cid, c, struct{}{}, pkey(), 404)
	h.call(t, "POST", "/v1/social/reports", c, social.Report{TargetType: "COMMENT", TargetID: cid, Reason: "ABUSE"}, pkey(), 200)
	h.call(t, "POST", "/v1/social/reports", c, social.Report{TargetType: "POST", TargetID: pid, Reason: "SPAM"}, pkey(), 200)
	h.call(t, "POST", "/v1/social/reports", c, social.Report{TargetType: "USER", TargetID: b.user, Reason: "PRIVACY"}, pkey(), 200)
	operate := func(action, id string) {
		t.Helper()
		if _, e := social.Operate(context.Background(), pool, "operator-test", "case-social-07", action, id); e != nil {
			t.Fatal(e)
		}
	}
	operate("hide-comment", cid)
	if sget(t, h, a, pid)["comment_count"] != float64(0) {
		t.Fatal("hidden comment counted")
	}
	page := smap(t, h.call(t, "GET", path+"/comments", a, nil, nil, 200))
	if len(page["items"].([]any)) != 0 {
		t.Fatal("hidden comments returned")
	}
	operate("show-comment", cid)
	h.call(t, "DELETE", path+"/comments/"+cid, a, struct{}{}, pkey(), 200)
	operate("hide-post", pid)
	h.call(t, "GET", path, a, nil, nil, 404)
	h.call(t, "PUT", path+"/like", b, struct{}{}, pkey(), 404)
	h.call(t, "POST", path+"/comments", b, map[string]any{"body": "Não"}, pkey(), 404)
	operate("show-post", pid)
	operate("restrict-user", a.user)
	h.call(t, "GET", path, b, nil, nil, 404)
	h.call(t, "POST", "/v1/social/posts", a, social.Input{Context: "PERSONAL", Visibility: "PUBLIC", Body: "Negado", MediaIDs: []string{}}, pkey(), 403)
	operate("restore-user", a.user)
	rows, e := social.Operate(context.Background(), pool, "operator-test", "case-social-07", "reports", "")
	if e != nil || len(rows) < 3 {
		t.Fatal("operational reports")
	}
	operate("posts", a.user)
	operate("post", pid)
	var audit, events, likes int
	pool.QueryRow(context.Background(), "SELECT count(*) FROM social.audit WHERE resource_id=$1", pid).Scan(&audit)
	pool.QueryRow(context.Background(), "SELECT count(*) FROM integration.outbox WHERE aggregate_id=$1 AND event_type LIKE 'social.%'", pid).Scan(&events)
	pool.QueryRow(context.Background(), "SELECT count(*) FROM social.likes WHERE post_id=$1", pid).Scan(&likes)
	if audit < 5 || events < 5 || likes != 0 {
		t.Fatal("audit/outbox/like consistency")
	}
	h.request(t, "POST", "/v1/social/posts", a, []byte(`{"body":"x","body":"y","context":"PERSONAL","visibility":"PUBLIC","media_ids":[]}`), pkey(), 400)
	exec(t, "UPDATE social.rate_limits SET count=120 WHERE user_id=$1", b.user)
	h.call(t, "PUT", path+"/like", b, struct{}{}, pkey(), 429)
}
func TestSocialExperienceEligibilityRevocation(t *testing.T) {
	h := newHarness(t)
	owner, a, b := user(t, true), user(t, true), user(t, true)
	makePost := func(eid string, actor actor, want int) string {
		in := social.Input{Context: "EXPERIENCE_PUBLIC", ExperienceID: &eid, Visibility: "PUBLIC", Body: "Um momento da experiência", MediaIDs: []string{}}
		r := h.call(t, "POST", "/v1/social/posts", actor, in, pkey(), want)
		if want != 200 {
			return ""
		}
		return smap(t, r)["id"].(string)
	}
	for _, v := range []string{"UNLISTED", "PRIVATE"} {
		e := publish(t, h, owner, create(t, h, owner, fullInput(v)))
		makePost(e.ID, owner, 404)
	}
	e := publish(t, h, owner, create(t, h, owner, fullInput("PUBLIC")))
	makePost(e.ID, a, 404)
	ownerPost := makePost(e.ID, owner, 200)
	h.call(t, "POST", pbase(e)+"/participation/confirm", a, struct{}{}, pkey(), 200)
	post := makePost(e.ID, a, 200)
	h.call(t, "GET", "/v1/social/experience-options", a, nil, nil, 200)
	h.call(t, "POST", pbase(e)+"/participants/"+a.user+"/remove", owner, struct{}{}, pkey(), 200)
	h.call(t, "GET", "/v1/social/posts/"+post, b, nil, nil, 404)
	sget(t, h, b, ownerPost)
	e = experience(t, h.call(t, "POST", pbase(e)+"/cancel", owner, struct{}{}, match(e), 200))
	h.call(t, "GET", "/v1/social/posts/"+ownerPost, b, nil, nil, 404)
}
func socialUpload(t *testing.T, h *harness, a actor, ct string, b []byte) media.FlowAsset {
	t.Helper()
	var init media.Initiated
	r := h.call(t, "POST", "/v1/social/media", a, media.InitiateRequest{ContentType: ct, SizeBytes: int64(len(b))}, pkey(), 200)
	if e := json.Unmarshal(r.raw, &init); e != nil {
		t.Fatal(e)
	}
	if status := upload(t, init.Upload, b, nil); status != 204 {
		t.Fatalf("S3 upload %d", status)
	}
	r = h.call(t, "POST", "/v1/social/media/"+init.MediaID+"/confirm", a, struct{}{}, nil, 200)
	var asset media.FlowAsset
	json.Unmarshal(r.raw, &asset)
	if asset.Status != "PROCESSING" {
		t.Fatal("confirmation must enqueue")
	}
	if worked, e := h.media.ProcessFlowNext(context.Background()); e != nil || !worked {
		t.Fatal("real media worker", e)
	}
	r = h.call(t, "GET", "/v1/social/media/"+init.MediaID, a, nil, nil, 200)
	json.Unmarshal(r.raw, &asset)
	return asset
}
func TestSocialRealMediaOwnershipVideoAndRevocation(t *testing.T) {
	h := newHarness(t)
	a, b := user(t, true), user(t, true)
	img := socialUpload(t, h, a, "image/png", imageBytes(t, 77))
	if img.Status != "READY" {
		t.Fatal("real image not ready")
	}
	h.call(t, "GET", "/v1/social/media/"+img.ID, b, nil, nil, 404)
	h.call(t, "POST", "/v1/social/posts", b, social.Input{Context: "PERSONAL", Visibility: "PUBLIC", MediaIDs: []string{img.ID}}, pkey(), 422)
	bad := socialUpload(t, h, a, "image/png", []byte("fake PNG"))
	if bad.Status != "FAILED" {
		t.Fatal("MIME trusted")
	}
	dir := t.TempDir()
	video := filepath.Join(dir, "video.mp4")
	for _, seconds := range []int{1, 16} {
		cmd := osexec.Command("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=320x240:r=30", "-t", fmt.Sprint(seconds), "-c:v", "libx264", "-threads", "1", "-pix_fmt", "yuv420p", "-y", video)
		if out, e := cmd.CombinedOutput(); e != nil {
			t.Fatalf("video fixture %s", out)
		}
		raw, _ := os.ReadFile(video)
		asset := socialUpload(t, h, a, "video/mp4", raw)
		if seconds == 16 {
			if asset.Status != "FAILED" {
				t.Fatal("overlong video")
			}
			continue
		}
		if asset.Status != "READY" || asset.DurationMS == nil || *asset.DurationMS > 15000 {
			t.Fatal("real video processing")
		}
		own := smap(t, h.call(t, "GET", "/v1/social/media/"+asset.ID, a, nil, nil, 200))
		preview := "/" + own["url"].(string)
		h.call(t, "GET", preview, actor{}, nil, nil, 200)
		pid := spost(t, h, a, "PUBLIC", "", asset.ID, img.ID)
		d := sget(t, h, b, pid)
		m := d["media"].([]any)[0].(map[string]any)
		path := "/" + m["url"].(string)
		res := h.call(t, "GET", path, actor{}, nil, nil, 200)
		if !bytes.Contains(res.raw, []byte("ftyp")) {
			t.Fatal("actual MP4")
		}
		poster := h.call(t, "GET", "/"+m["poster_url"].(string), actor{}, nil, nil, 200)
		if len(poster.raw) < 3 || poster.raw[0] != 255 {
			t.Fatal("real poster")
		}
		h.call(t, "GET", path, actor{}, nil, map[string]string{"Range": "bytes=0-31"}, 206)
		viewer := user(t, true)
		viewed := sget(t, h, viewer, pid)
		viewMedia := viewed["media"].([]any)[0].(map[string]any)
		sessionURL := "/" + viewMedia["url"].(string)
		h.call(t, "GET", sessionURL, actor{}, nil, nil, 200)
		exec(t, "UPDATE identity.sessions SET revoked_at=now(),revocation_reason='integration' WHERE id=$1", viewer.session)
		h.call(t, "GET", sessionURL, actor{}, nil, nil, 404)
		h.call(t, "GET", strings.Replace(path, asset.ID, img.ID, 1), actor{}, nil, nil, 404)

		srelation(t, h, a, b.user, "block", "PUT")
		h.call(t, "GET", path, actor{}, nil, nil, 404)
		srelation(t, h, a, b.user, "block", "DELETE")
		sget(t, h, b, pid)
		if _, e := social.Operate(context.Background(), pool, "operator-test", "case-media-07", "hide-post", pid); e != nil {
			t.Fatal(e)
		}
		h.call(t, "GET", path, actor{}, nil, nil, 404)
		h.call(t, "GET", preview, actor{}, nil, nil, 404)
		h.call(t, "GET", "/v1/social/media/"+asset.ID, a, nil, nil, 404)
		h.call(t, "DELETE", "/v1/social/posts/"+pid, a, struct{}{}, pkey(), 200)
		h.call(t, "GET", path, actor{}, nil, nil, 404)
		exec(t, "UPDATE media.flow_assets SET created_at=now()-interval '25 hours',expires_at=now()-interval '2 hours' WHERE id IN ($1,$2)", asset.ID, img.ID)
		if _, e := h.media.CleanupFlows(context.Background()); e != nil {
			t.Fatal(e)
		}
		var n int
		pool.QueryRow(context.Background(), "SELECT count(*) FROM media.flow_assets WHERE id IN ($1,$2) AND status='DELETED'", asset.ID, img.ID).Scan(&n)
		if n != 2 {
			t.Fatal("deleted media retained")
		}
	}
	// No API authentication bypass or privileged route exists.
	h.call(t, "GET", "/v1/social/feed", actor{}, nil, nil, 401)
}

func TestSocialStoredEventContractsAndCleanup(t *testing.T) {
	h := newHarness(t)
	a := user(t, true)
	spost(t, h, a, "PUBLIC", "Contrato durável independente")
	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.AssertFormat()
	schema, e := compiler.Compile("../../../../contracts/events/social-payload.schema.json")
	if e != nil {
		t.Fatal(e)
	}
	rows, e := pool.Query(context.Background(), "SELECT event_type,payload FROM integration.outbox WHERE event_type LIKE 'social.%'")
	if e != nil {
		t.Fatal(e)
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		var event string
		var raw []byte
		if e = rows.Scan(&event, &raw); e != nil {
			t.Fatal(e)
		}
		if !regexp.MustCompile(`^[a-z]+(?:\.[a-z_]+)+$`).MatchString(event) {
			t.Fatal("invalid event name", event)
		}
		v, e := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
		if e != nil {
			t.Fatal(e)
		}
		if e = schema.Validate(v); e != nil {
			t.Fatal("payload contract", e)
		}
		count++
	}
	if count == 0 {
		t.Fatal("no real events")
	}
	if e := dbgen.New(pool).SocialCleanup(context.Background()); e != nil {
		t.Fatal(e)
	}
}

func TestSocialCommentsCursorAndObserverCounts(t *testing.T) {
	h := newHarness(t)
	a, b, c := user(t, true), user(t, true), user(t, true)
	pid := spost(t, h, a, "PUBLIC", "Comentários e observadores")
	base := "/v1/social/posts/" + pid
	srelation(t, h, b, a.user, "follow", "PUT")
	srelation(t, h, c, a.user, "follow", "PUT")
	for _, actor := range []actor{b, c} {
		h.call(t, "PUT", base+"/like", actor, struct{}{}, pkey(), 200)
		h.call(t, "POST", base+"/comments", actor, map[string]any{"body": "Comentário autorizado"}, pkey(), 200)
	}
	page := smap(t, h.call(t, "GET", base+"/comments?limit=1", b, nil, nil, 200))
	cursor := page["next_cursor"].(string)
	first := page["items"].([]any)[0].(map[string]any)["id"]
	next := smap(t, h.call(t, "GET", base+"/comments?limit=1&cursor="+url.QueryEscape(cursor), b, nil, nil, 200))
	if next["items"].([]any)[0].(map[string]any)["id"] == first {
		t.Fatal("comment page repeated")
	}
	srelation(t, h, b, c.user, "block", "PUT")
	visible := sget(t, h, b, pid)
	owner := sget(t, h, a, pid)
	if visible["like_count"] != float64(1) || visible["comment_count"] != float64(1) || owner["like_count"] != float64(2) || owner["comment_count"] != float64(2) {
		t.Fatal("engagement leaked blocked account")
	}
	comments := smap(t, h.call(t, "GET", base+"/comments", b, nil, nil, 200))
	if len(comments["items"].([]any)) != 1 {
		t.Fatal("blocked comment returned")
	}
	profile := smap(t, h.call(t, "GET", "/v1/social/profiles/"+a.user, b, nil, nil, 200))
	if profile["follower_count"] != float64(1) {
		t.Fatal("blocked user counted in alternate profile")
	}
	people := smap(t, h.call(t, "GET", "/v1/social/profiles/"+a.user+"/followers", b, nil, nil, 200))
	if len(people["items"].([]any)) != 1 {
		t.Fatal("alternate graph bypass")
	}
}
