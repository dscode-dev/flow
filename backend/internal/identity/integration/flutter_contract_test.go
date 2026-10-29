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
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"flow.local/backend/internal/identity"
	"github.com/getkin/kin-openapi/openapi3filter"
)

// This bridge exists ONLY in an integration-test binary and flow_identity_test.
// OAuth/SMS upstreams are the explicit fixtures from TestMain, never real providers.
func TestFlutterIdentityContract(t *testing.T) {
	flutter := os.Getenv("FLOW_FLUTTER_CONTRACT_BIN")
	if flutter == "" {
		t.Skip("use make identity-mobile-contract for the Flutter/Go/PostgreSQL contract")
	}
	h := newHarness(t, func(c *identity.Config) { c.OriginMinute = 1000 })
	api := h.server.Config.Handler
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/__fixture/proof" {
			var body struct{ Provider, Nonce string }
			if r.Method != "POST" || json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body) != nil ||
				(body.Provider != "GOOGLE" && body.Provider != "APPLE") || body.Nonce == "" {
				w.WriteHeader(400)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"token": token(t, body.Provider, "flutter-fixture-"+body.Provider, body.Nonce)})
			return
		}
		if r.URL.Path == "/__fixture/expire-access" || r.URL.Path == "/__fixture/suspend" {
			var body struct{ User string }
			if r.Method != "POST" || json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body) != nil {
				w.WriteHeader(400)
				return
			}
			query := `UPDATE identity.access_credentials SET expires_at=now()-interval '1 second' WHERE session_id IN (SELECT id FROM identity.sessions WHERE user_id=$1)`
			if r.URL.Path == "/__fixture/suspend" {
				query = `UPDATE identity.users SET status='suspended' WHERE id=$1`
			}
			if _, err := pool.Exec(r.Context(), query, body.User); err != nil {
				w.WriteHeader(400)
				return
			}
			w.WriteHeader(204)
			return
		}
		recorded := httptest.NewRecorder()
		api.ServeHTTP(recorded, r)
		response := recorded.Result()
		route, params, err := contract.FindRoute(r)
		if err == nil {
			err = openapi3filter.ValidateResponse(r.Context(), &openapi3filter.ResponseValidationInput{
				RequestValidationInput: &openapi3filter.RequestValidationInput{Request: r, PathParams: params, Route: route},
				Status:                 response.StatusCode, Header: response.Header, Body: io.NopCloser(bytes.NewReader(recorded.Body.Bytes())),
			})
		}
		if err != nil {
			t.Errorf("Flutter response violates OpenAPI at %s %s (payload withheld)", r.Method, r.URL.Path)
		}
		for k, values := range response.Header {
			for _, value := range values {
				w.Header().Add(k, value)
			}
		}
		w.WriteHeader(response.StatusCode)
		_, _ = w.Write(recorded.Body.Bytes())
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, flutter, "test", "test/identity_contract_test.dart", "--dart-define=FLOW_IDENTITY_CONTRACT_URL="+server.URL+"/")
	cmd.Dir = filepath.Join("..", "..", "..", "..", "apps", "mobile")
	// Only test output; fixtures and real session credentials are never logged.
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Flutter/Go contract failed: %v\n%s", err, output)
	}
	t.Log(string(output))
}
