//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	osexec "os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"flow.local/backend/internal/identity"
)

func TestFlutterFlowsNative(t *testing.T) {
	flutter, device := os.Getenv("FLOW_FLUTTER_CONTRACT_BIN"), os.Getenv("FLOW_NATIVE_DEVICE")
	if flutter == "" || device == "" {
		t.Skip("set FLOW_NATIVE_DEVICE and FLOW_FLUTTER_CONTRACT_BIN for native execution")
	}
	h := newHarness(t)
	owner, viewer := user(t, true), user(t, true)
	now := time.Now().UTC()
	eid := homeFixture(t, owner, now, now.Add(time.Hour), 0, 0)
	file := filepath.Join(t.TempDir(), "clip.mp4")
	if e := osexec.CommandContext(t.Context(), "ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=96x128:r=30", "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", file).Run(); e != nil {
		t.Fatal("test video generation failed")
	}
	raw, e := os.ReadFile(file)
	if e != nil {
		t.Fatal(e)
	}
	asset := flowUpload(t, h, owner, eid, "video/mp4", raw)
	if asset.Status != "READY" {
		t.Fatal("test video not ready")
	}
	putPresentation(t, h, owner, eid, 0, map[string]any{"enabled": true, "video_asset_id": asset.ID}, 200)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/__fixture/flow" {
			item, e := h.service.Flow(r.Context(), &identity.Session{ID: viewer.session, UserID: viewer.user}, eid)
			if e != nil {
				w.WriteHeader(500)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(item)
			return
		}
		h.server.Config.Handler.ServeHTTP(w, r)
	}))
	defer server.Close()
	// Leave room before go test's default10m deadline and terminate the runner's
	// process group, so a slow native build cannot leave a Flutter lock orphaned.
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Minute)
	defer cancel()
	cmd := osexec.CommandContext(ctx, flutter, "test", "integration_test/flows_native_test.dart", "-d", device, "--dart-define=FLOW_NATIVE_CONTRACT_URL="+server.URL+"/")
	cmd.Dir = filepath.Join("..", "..", "..", "..", "apps", "mobile")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	cmd.WaitDelay = 3 * time.Second
	runnerLog, e := os.CreateTemp("", "flow-pr05-native-runner-*.log")
	if e != nil {
		t.Fatal(e)
	}
	defer runnerLog.Close()
	cmd.Stdout = runnerLog
	cmd.Stderr = runnerLog
	t.Logf("Native runner log: %s", runnerLog.Name())
	e = cmd.Run()
	out, _ := os.ReadFile(runnerLog.Name())
	if len(out) > 16000 {
		out = out[len(out)-16000:]
	}
	if e != nil {
		t.Fatalf("native media integration failed: %v\n%s", e, out)
	}
	t.Log(string(out))
}
