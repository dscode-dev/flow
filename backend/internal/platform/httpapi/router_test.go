package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers/legacy"
)

type checks struct {
	available bool
	calls     int
}

func (c *checks) Check(context.Context) map[string]bool {
	c.calls++
	return map[string]bool{"postgres": c.available, "redis": c.available, "rabbitmq": c.available}
}
func TestHealthReadinessAndErrors(t *testing.T) {
	checker := &checks{}
	draining := false
	handler := New(slog.New(slog.NewTextHandler(io.Discard, nil)), checker, 32, time.Second, func() bool { return draining })
	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromFile("../../../../contracts/openapi/flow.yaml")
	if err != nil {
		t.Fatal(err)
	}
	contract, err := legacy.NewRouter(doc)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		path         string
		ready, drain bool
		status       int
	}{
		{"/healthz", false, false, 200}, {"/readyz", false, false, 503}, {"/readyz", true, false, 200}, {"/readyz", true, true, 503}, {"/missing", true, false, 404},
	} {
		checker.available = tc.ready
		draining = tc.drain
		request := httptest.NewRequest(http.MethodGet, tc.path, nil)
		request.Header.Set("X-Request-ID", "<unsafe-id>")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != tc.status {
			t.Fatalf("%s: %d", tc.path, response.Code)
		}
		if !validID.MatchString(response.Header().Get("X-Request-ID")) {
			t.Fatal("invalid request id")
		}
		if response.Code >= 400 {
			var envelope Envelope
			if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
				t.Fatal(err)
			}
			if envelope.Error.RequestID != response.Header().Get("X-Request-ID") {
				t.Fatal("correlation mismatch")
			}
		}
		if tc.path != "/missing" {
			route, params, err := contract.FindRoute(request)
			if err != nil {
				t.Fatal(err)
			}
			input := &openapi3filter.ResponseValidationInput{RequestValidationInput: &openapi3filter.RequestValidationInput{Request: request, PathParams: params, Route: route}, Status: response.Code, Header: response.Header(), Body: io.NopCloser(strings.NewReader(response.Body.String()))}
			if err := openapi3filter.ValidateResponse(context.Background(), input); err != nil {
				t.Fatal(err)
			}
		}
	}
	if checker.calls != 2 {
		t.Fatalf("liveness/draining must not probe dependencies; calls=%d", checker.calls)
	}
	request := httptest.NewRequest(http.MethodPost, "/healthz", strings.NewReader(strings.Repeat("x", 33)))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != 413 {
		t.Fatal("body limit not enforced")
	}
	request = httptest.NewRequest(http.MethodPost, "/healthz", nil)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != 405 {
		t.Fatal("method must be rejected")
	}
}

func TestLogsOmitSensitiveInputs(t *testing.T) {
	var logs bytes.Buffer
	handler := New(slog.New(slog.NewJSONHandler(&logs, nil)), &checks{available: true}, 1024, time.Second, func() bool { return false })
	r := httptest.NewRequest(http.MethodGet, "/healthz?token=sensitive-token&lat=precise-location", nil)
	r.Header.Set("Authorization", "Bearer sensitive-token")
	r.Header.Set("X-Request-ID", "safe-request-id")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if strings.Contains(logs.String(), "sensitive-token") || strings.Contains(logs.String(), "precise-location") {
		t.Fatal("sensitive request input leaked to log")
	}
	if !strings.Contains(logs.String(), `"status":200`) || !strings.Contains(logs.String(), "safe-request-id") {
		t.Fatal("missing operational correlation")
	}
	if w.Header().Get("X-Request-ID") != "safe-request-id" {
		t.Fatal("valid correlation ID not preserved")
	}
}
