//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/getkin/kin-openapi/openapi3filter"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	osexec "os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// Authentication fixtures exist only in this test binary. All domain operations
// below run through the Flutter repository and the real API/PostgreSQL contracts.
func TestFlutterEventSpaceContract(t *testing.T) {
	flutter := os.Getenv("FLOW_FLUTTER_CONTRACT_BIN")
	if flutter == "" {
		t.Skip("set FLOW_FLUTTER_CONTRACT_BIN and run make experiences-test with this filter")
	}
	h := newHarness(t)
	owner, participant := user(t, true), user(t, true)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/__fixture/session" && r.Method == "GET" {
			a := owner
			if r.URL.Query().Get("actor") == "participant" {
				a = participant
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"access": a.token, "user_id": a.user, "session_id": a.session})
			return
		}
		recorded := httptest.NewRecorder()
		h.server.Config.Handler.ServeHTTP(recorded, r)
		res := recorded.Result()
		route, params, err := contract.FindRoute(r)
		if err == nil {
			err = openapi3filter.ValidateResponse(r.Context(), &openapi3filter.ResponseValidationInput{RequestValidationInput: &openapi3filter.RequestValidationInput{Request: r, PathParams: params, Route: route}, Status: res.StatusCode, Header: res.Header, Body: io.NopCloser(bytes.NewReader(recorded.Body.Bytes()))})
		}
		if err != nil {
			t.Errorf("Event Space response violates OpenAPI: %s %s (payload withheld)", r.Method, r.URL.Path)
		}
		for k, v := range res.Header {
			w.Header()[k] = v
		}
		w.WriteHeader(res.StatusCode)
		_, _ = w.Write(recorded.Body.Bytes())
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Minute)
	defer cancel()
	cmd := osexec.CommandContext(ctx, flutter, "test", "test/event_space_contract_test.dart", "--dart-define=FLOW_EVENT_SPACE_CONTRACT_URL="+server.URL+"/")
	cmd.Dir = filepath.Join("..", "..", "..", "..", "apps", "mobile")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
		return nil
	}
	cmd.WaitDelay = 3 * time.Second
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Flutter/Go/PostgreSQL Event Space contract: %v\n%s", err, output)
	}
	t.Log(string(output))
}
