package telemetry

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/trace"
)

func TestExportUsesTracePath(t *testing.T) {
	paths := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		paths <- r.URL.Path
		w.Header().Set("Content-Type", "application/x-protobuf")
		w.WriteHeader(200)
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	shutdown, err := Setup(ctx, server.URL, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	// Parent amostrado evita teste probabilístico com sampler de 10%.
	parent := trace.NewSpanContext(trace.SpanContextConfig{TraceID: trace.TraceID{1}, SpanID: trace.SpanID{1}, TraceFlags: trace.FlagsSampled})
	_, span := otel.Tracer("test").Start(trace.ContextWithRemoteSpanContext(ctx, parent), "probe")
	span.End()
	if err := shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case path := <-paths:
		if path != "/v1/traces" {
			t.Fatalf("unexpected trace endpoint %s", path)
		}
	case <-ctx.Done():
		t.Fatal("no trace received")
	}
}
