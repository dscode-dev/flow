//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	osexec "os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/getkin/kin-openapi/openapi3filter"
)

// The fixture bridge exists exclusively in this integration-test binary, using
// flow_experiences_test and the isolated S3 bucket. Never an application route.
func TestFlutterExperiencesContract(t *testing.T) {
	flutter := os.Getenv("FLOW_FLUTTER_CONTRACT_BIN")
	if flutter == "" {
		t.Skip("use make experiences-mobile-contract")
	}
	h := newHarness(t)
	workerCtx, stopWorker := context.WithCancel(t.Context())
	workerDone := make(chan struct{})
	defer func() { stopWorker(); <-workerDone }()
	go func() {
		defer close(workerDone)
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-workerCtx.Done():
				return
			case <-ticker.C:
				_, _ = h.media.ProcessFlowNext(workerCtx)
			}
		}
	}()
	owner, other := user(t, true), user(t, true)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/__fixture/session" && r.Method == "GET" {
			a := owner
			if r.URL.Query().Get("actor") == "other" {
				a = other
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"access": a.token, "user_id": a.user, "session_id": a.session})
			return
		}
		if r.URL.Path == "/__fixture/revoke" && r.Method == "POST" {
			_, err := pool.Exec(r.Context(), "UPDATE identity.sessions SET revoked_at=now(),revocation_reason='integration' WHERE id=$1", owner.session)
			if err != nil {
				w.WriteHeader(500)
			} else {
				w.WriteHeader(204)
			}
			return
		}
		recorded := httptest.NewRecorder()
		h.server.Config.Handler.ServeHTTP(recorded, r)
		response := recorded.Result()
		route, params, err := contract.FindRoute(r)
		if err == nil {
			err = openapi3filter.ValidateResponse(r.Context(), &openapi3filter.ResponseValidationInput{
				RequestValidationInput: &openapi3filter.RequestValidationInput{Request: r, PathParams: params, Route: route},
				Status:                 response.StatusCode, Header: response.Header, Body: io.NopCloser(bytes.NewReader(recorded.Body.Bytes())),
			})
		}
		if err != nil {
			t.Errorf("Flutter/Experiences response violates OpenAPI at %s %s (payload withheld)", r.Method, r.URL.Path)
		}
		for k, values := range response.Header {
			for _, v := range values {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(response.StatusCode)
		_, _ = w.Write(recorded.Body.Bytes())
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Minute)
	defer cancel()
	cmd := osexec.CommandContext(ctx, flutter, "test", "test/experiences_contract_test.dart", "--dart-define=FLOW_EXPERIENCES_CONTRACT_URL="+server.URL+"/")
	cmd.Dir = filepath.Join("..", "..", "..", "..", "apps", "mobile")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Flutter/Go/PostGIS/S3 contract failed: %v\n%s", err, output)
	}
	t.Log(string(output))
}
