//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"flow.local/backend/internal/experiences"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/media"
	"github.com/google/uuid"
)

func flowPage(t *testing.T, h *harness, a actor, q string) experiences.FlowsPage {
	t.Helper()
	r := h.call(t, "GET", "/v1/flows"+q, a, nil, nil, 200)
	var p experiences.FlowsPage
	if e := json.Unmarshal(r.raw, &p); e != nil {
		t.Fatal(e)
	}
	return p
}

func TestFlowUploadConcurrentIdempotency(t *testing.T) {
	h := newHarness(t)
	a := user(t, true)
	now := time.Now().UTC()
	eid := homeFixture(t, a, now, now.Add(time.Hour), 0, 0)
	session := &identity.Session{ID: a.session, UserID: a.user}
	key := uuid.NewString()
	raw := imageBytes(t, 31)
	in := media.InitiateRequest{ContentType: "image/png", SizeBytes: int64(len(raw))}
	type initiated struct {
		value media.Initiated
		err   error
	}
	results := make(chan initiated, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			v, e := h.media.InitiateFlow(t.Context(), session, eid, key, in, "concurrent")
			results <- initiated{v, e}
		}()
	}
	wg.Wait()
	close(results)
	var auth media.Initiated
	for r := range results {
		if r.err != nil {
			t.Fatal(r.err)
		}
		if auth.MediaID != "" && auth.MediaID != r.value.MediaID {
			t.Fatal("duplicate logical upload")
		}
		auth = r.value
	}
	if upload(t, auth.Upload, raw, nil) != 204 {
		t.Fatal("upload")
	}
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := h.media.ConfirmFlow(t.Context(), session, eid, auth.MediaID, "concurrent")
			errs <- e
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	type processed struct {
		worked bool
		err    error
	}
	work := make(chan processed, 2)
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); w, e := h.media.ProcessFlowNext(t.Context()); work <- processed{w, e} }()
	}
	wg.Wait()
	close(work)
	claimed := 0
	for r := range work {
		if r.err != nil {
			t.Fatal(r.err)
		}
		if r.worked {
			claimed++
		}
	}
	if claimed != 1 {
		t.Fatal("job claimed more than once")
	}
	var queued, ready int
	e := pool.QueryRow(t.Context(), "SELECT count(*) FILTER(WHERE action='flow.media.queued'),count(*) FILTER(WHERE action='flow.media.ready') FROM experiences.flow_audit WHERE experience_id=$1", eid).Scan(&queued, &ready)
	if e != nil || queued != 1 || ready != 1 {
		t.Fatal("duplicate processing/audit", e, queued, ready)
	}
}
func putPresentation(t *testing.T, h *harness, a actor, eid string, version int64, in any, status int) experiences.FlowPresentation {
	t.Helper()
	r := h.call(t, "PUT", "/v1/experiences/"+eid+"/flow", a, in, map[string]string{"If-Match": fmt.Sprintf("\"%d\"", version)}, status)
	var p experiences.FlowPresentation
	if status == 200 {
		if e := json.Unmarshal(r.raw, &p); e != nil {
			t.Fatal(e)
		}
	}
	return p
}
func flowUpload(t *testing.T, h *harness, a actor, eid, ct string, b []byte) media.FlowAsset {
	t.Helper()
	path := "/v1/experiences/" + eid + "/flow/media"
	r := h.call(t, "POST", path, a, map[string]any{"content_type": ct, "size_bytes": len(b)}, map[string]string{"Idempotency-Key": uuid.NewString()}, 201)
	var init media.Initiated
	if e := json.Unmarshal(r.raw, &init); e != nil {
		t.Fatal(e)
	}
	if upload(t, init.Upload, b, nil) != 204 {
		t.Fatal("S3 upload")
	}
	confirm := path + "/" + init.MediaID + "/confirm"
	h.call(t, "POST", confirm, a, map[string]any{}, nil, 202)
	h.call(t, "POST", confirm, a, map[string]any{}, nil, 202)
	for range 10 {
		worked, e := h.media.ProcessFlowNext(t.Context())
		if e != nil {
			t.Fatal(e)
		}
		if !worked {
			break
		}
	}
	var out media.FlowAsset
	r = h.call(t, "GET", path+"/"+init.MediaID, a, nil, nil, 200)
	if e := json.Unmarshal(r.raw, &out); e != nil {
		t.Fatal(e)
	}
	return out
}
func TestExploreSearchAndFlowsConsent(t *testing.T) {
	h := newHarness(t)
	a, b := user(t, true), user(t, true)
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD'")
	now := time.Now().UTC()
	pub := homeFixture(t, a, now.Add(-time.Hour), now.Add(time.Hour), -8.05, -34.88)
	exec(t, "UPDATE experiences.experiences SET title='Encontro de música na praça',description='Apresentação acústica com cultura e educação na cidade' WHERE id=$1", pub)
	image := flowUpload(t, h, a, pub, "image/png", imageBytes(t, 90))
	if image.Status != "READY" {
		t.Fatal("image processing", image.Status)
	}
	putPresentation(t, h, a, pub, 0, map[string]any{"enabled": true, "image_asset_id": image.ID}, 200)
	p := flowPage(t, h, b, "")
	if len(p.Items) != 1 || p.Items[0].Experience.ID != pub || p.Items[0].Experience.Phase == nil || *p.Items[0].Experience.Phase != "LIVE" {
		t.Fatal("public flow")
	}
	// Actual temporary URL, S3 bytes, and progressive Range; no Bearer required by player.
	content := "/" + p.Items[0].ImageURL
	h.call(t, "GET", content, actor{}, nil, nil, 200)
	h.call(t, "GET", content, actor{}, nil, map[string]string{"Range": "bytes=0-15"}, 206)
	r := h.call(t, "GET", "/v1/explore/experiences?q=musica", b, nil, nil, 200)
	var search experiences.ExplorePage
	json.Unmarshal(r.raw, &search)
	if len(search.Items) != 1 || search.Items[0].ID != pub {
		t.Fatal("accent/stemming search")
	}
	h.call(t, "GET", "/v1/explore/experiences?q=educacao&category_id=nature", b, nil, nil, 200)
	for _, query := range []string{"?limit=0", "?limit=51", "?q=" + strings.Repeat("x", 121), "?q=ok&q=again", "?paid=true", "?latitude=0", "?from=2026-01-01T00:00:00Z"} {
		h.call(t, "GET", "/v1/explore/experiences"+query, b, nil, nil, 400)
	}
	unlisted := homeFixture(t, a, now.Add(time.Hour), now.Add(2*time.Hour), -8.05, -34.88)
	exec(t, "UPDATE experiences.experiences SET visibility='UNLISTED' WHERE id=$1", unlisted)
	ui := flowUpload(t, h, a, unlisted, "image/png", imageBytes(t, 100))
	h.call(t, "GET", "/v1/flows/"+unlisted, b, nil, nil, 404)
	putPresentation(t, h, a, unlisted, 0, map[string]any{"enabled": true, "image_asset_id": ui.ID}, 422)
	up := putPresentation(t, h, a, unlisted, 0, map[string]any{"enabled": true, "unlisted_consent": true, "image_asset_id": ui.ID}, 200)
	if up.UnlistedConsentAt == nil {
		t.Fatal("consent audit time")
	}
	p = flowPage(t, h, b, "?limit=1")
	if p.NextCursor == nil || len(p.Items) != 1 || p.Items[0].Experience.ID != pub {
		t.Fatal("phase/page ordering")
	}
	second := flowPage(t, h, b, "?limit=1&cursor="+*p.NextCursor)
	if len(second.Items) != 1 || second.Items[0].Experience.ID != unlisted {
		t.Fatal("continuation")
	}
	h.call(t, "GET", "/v1/flows?limit=2&cursor="+*p.NextCursor, b, nil, nil, 400)
	h.call(t, "GET", "/v1/explore/experiences?cursor="+*p.NextCursor, b, nil, nil, 400)
	h.call(t, "GET", "/v1/experiences/"+unlisted+"/flow", b, nil, nil, 404)
	putPresentation(t, h, b, unlisted, up.Version, map[string]any{"enabled": false}, 404)
	putPresentation(t, h, a, unlisted, 0, map[string]any{"enabled": false}, 412)
	oldURL := "/" + second.Items[0].ImageURL
	up = putPresentation(t, h, a, unlisted, up.Version, map[string]any{"enabled": false}, 200)
	if up.UnlistedConsentAt != nil {
		t.Fatal("revoke consent")
	}
	h.call(t, "GET", oldURL, actor{}, nil, nil, 404)
	putPresentation(t, h, a, unlisted, up.Version, map[string]any{"enabled": true}, 422)
	// PRIVATE can never become discoverable, even with a consent flag.
	exec(t, "UPDATE experiences.experiences SET visibility='PRIVATE' WHERE id=$1", unlisted)
	putPresentation(t, h, a, unlisted, up.Version, map[string]any{"enabled": true, "unlisted_consent": true}, 403)
	exec(t, "UPDATE experiences.experiences SET status='CANCELLED',cancelled_at=now() WHERE id=$1", pub)
	h.call(t, "GET", content, actor{}, nil, nil, 404)
	if len(flowPage(t, h, b, "").Items) != 0 {
		t.Fatal("lifecycle withdrawal")
	}
}

func TestExploreFiltersAndFlowPolicy(t *testing.T) {
	h := newHarness(t)
	a, b := user(t, true), user(t, true)
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD'")
	now := time.Now().UTC().Truncate(time.Second)
	live := homeFixture(t, a, now.Add(-time.Hour), now.Add(time.Hour), -8.05, -34.88)
	future := homeFixture(t, a, now.Add(3*time.Hour), now.Add(4*time.Hour), -23.55, -46.63)
	outside := homeFixture(t, a, now.Add(49*time.Hour), now.Add(50*time.Hour), 0, 0)
	for _, eid := range []string{live, future, outside} {
		img := flowUpload(t, h, a, eid, "image/png", imageBytes(t, 75))
		putPresentation(t, h, a, eid, 0, map[string]any{"enabled": true, "image_asset_id": img.ID}, 200)
	}
	if len(flowPage(t, h, b, "").Items) != 2 {
		t.Fatal("future window")
	}
	query := func(q string) experiences.ExplorePage {
		r := h.call(t, "GET", "/v1/explore/experiences?"+q, b, nil, nil, 200)
		var p experiences.ExplorePage
		if e := json.Unmarshal(r.raw, &p); e != nil {
			t.Fatal(e)
		}
		return p
	}
	if p := query("phase=LIVE"); len(p.Items) != 1 || p.Items[0].ID != live {
		t.Fatal("phase")
	}
	if p := query("latitude=-8.05&longitude=-34.88&radius_m=1000"); len(p.Items) != 1 || p.Items[0].ID != live {
		t.Fatal("geographic filter")
	}
	p := query("from=" + now.Add(2*time.Hour).Format(time.RFC3339) + "&until=" + now.Add(5*time.Hour).Format(time.RFC3339))
	if len(p.Items) != 1 || p.Items[0].ID != future {
		t.Fatal("period overlap")
	}
	first := query("limit=1")
	if first.NextCursor == nil || first.Items[0].ID != live {
		t.Fatal("search page")
	}
	second := query("limit=1&cursor=" + *first.NextCursor)
	if len(second.Items) != 1 || second.Items[0].ID != future {
		t.Fatal("search cursor")
	}
	h.call(t, "GET", "/v1/explore/experiences?limit=1&category_id=nature&cursor="+*first.NextCursor, b, nil, nil, 400)
	// Content is withdrawn by creator/content restrictions and the live clock.
	item := flowPage(t, h, b, "?limit=1").Items[0]
	oldURL := "/" + item.ImageURL
	exec(t, "INSERT INTO experiences.publishing_restrictions(creator_user_id,blocked_until,reason_code) VALUES($1,now()+interval '1 hour','test')", a.user)
	if len(flowPage(t, h, b, "").Items) != 0 {
		t.Fatal("creator publishing restriction")
	}
	h.call(t, "GET", oldURL, actor{}, nil, nil, 404)
	exec(t, "DELETE FROM experiences.publishing_restrictions WHERE creator_user_id=$1", a.user)
	exec(t, "UPDATE identity.users SET status='suspended' WHERE id=$1", a.user)
	if len(flowPage(t, h, b, "").Items) != 0 {
		t.Fatal("inactive creator")
	}
	exec(t, "UPDATE identity.users SET status='active' WHERE id=$1", a.user)
	exec(t, "UPDATE experiences.experiences SET ends_at=now() WHERE id=$1", live)
	for _, item := range flowPage(t, h, b, "").Items {
		if item.Experience.ID == live {
			t.Fatal("ended flow")
		}
	}
	// Only media from the same owner AND Experience may be associated.
	img := flowUpload(t, h, a, future, "image/png", imageBytes(t, 74))
	putPresentation(t, h, a, live, 1, map[string]any{"enabled": false, "image_asset_id": img.ID}, 422)
	h.call(t, "GET", "/v1/experiences/"+future+"/flow/media/"+img.ID, b, nil, nil, 404)
	h.call(t, "POST", "/v1/experiences/"+future+"/flow/media/"+img.ID+"/confirm", b, map[string]any{}, nil, 404)
	var count int
	if e := pool.QueryRow(t.Context(), "SELECT count(*) FROM experiences.flow_audit WHERE experience_id=$1 AND details->>'enabled'='true' AND details->>'visibility'='PUBLIC'", future).Scan(&count); e != nil || count < 1 {
		t.Fatal("exposure audit", e)
	}
}
func TestFlowsRealVideoProcessingAndRevocation(t *testing.T) {
	if _, e := osexec.LookPath("ffmpeg"); e != nil {
		t.Fatal("FFmpeg required for real media integration")
	}
	h := newHarness(t)
	a, b := user(t, true), user(t, true)
	now := time.Now().UTC()
	eid := homeFixture(t, a, now, now.Add(time.Hour), 0, 0)
	generate := func(duration string) []byte {
		t.Helper()
		file := filepath.Join(t.TempDir(), "clip.mp4")
		cmd := osexec.CommandContext(t.Context(), "ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=96x128:r=15", "-t", duration, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", file)
		if e := cmd.Run(); e != nil {
			t.Fatal(e)
		}
		raw, e := os.ReadFile(file)
		if e != nil {
			t.Fatal(e)
		}
		return raw
	}
	video := flowUpload(t, h, a, eid, "video/mp4", generate("1"))
	if video.Status != "READY" || video.DurationMS == nil || *video.DurationMS > 15000 {
		t.Fatal("real video", video)
	}
	putPresentation(t, h, a, eid, 0, map[string]any{"enabled": true, "video_asset_id": video.ID}, 200)
	var view experiences.FlowItem
	r := h.call(t, "GET", "/v1/flows/"+eid, b, nil, nil, 200)
	json.Unmarshal(r.raw, &view)
	if !view.HasVideo || view.VideoURL == nil || view.ImageKind != "poster" {
		t.Fatal("video/poster")
	}
	h.call(t, "GET", "/"+*view.VideoURL, actor{}, nil, map[string]string{"Range": "bytes=0-255"}, 206)
	h.call(t, "GET", "/"+view.ImageURL, actor{}, nil, nil, 200)
	long := flowUpload(t, h, a, eid, "video/mp4", generate("16"))
	if long.Status != "FAILED" || long.FailureCode == nil {
		t.Fatal("overlong accepted")
	}
	fake := flowUpload(t, h, a, eid, "video/mp4", []byte("not really video"))
	if fake.Status != "FAILED" {
		t.Fatal("MIME trusted")
	}
	exec(t, "UPDATE identity.sessions SET revoked_at=now(),revocation_reason='integration' WHERE id=$1", b.session)
	h.call(t, "GET", "/"+*view.VideoURL, actor{}, nil, nil, 404)
	// Detach then age only this unbound test asset; cleanup removes S3 objects.
	exec(t, "UPDATE media.flow_assets SET created_at=now()-interval '25 hours',expires_at=now()-interval '24 hours' WHERE id=$1", long.ID)
	if _, e := h.media.CleanupFlows(context.Background()); e != nil {
		t.Fatal(e)
	}
	var status string
	if e := pool.QueryRow(t.Context(), "SELECT status FROM media.flow_assets WHERE id=$1", long.ID).Scan(&status); e != nil || status != "DELETED" {
		t.Fatal("orphan cleanup", e, status)
	}
}
