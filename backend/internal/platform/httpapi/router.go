package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"regexp"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

type Checker interface {
	Check(context.Context) map[string]bool
}
type ctxKey struct{}
type Envelope struct {
	Error struct {
		Code      string `json:"code"`
		Message   string `json:"message"`
		RequestID string `json:"request_id"`
	} `json:"error"`
}

func RequestID(ctx context.Context) string { v, _ := ctx.Value(ctxKey{}).(string); return v }
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func Error(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	var e Envelope
	e.Error.Code = code
	e.Error.Message = message
	e.Error.RequestID = RequestID(r.Context())
	writeJSON(w, status, e)
}

var validID = regexp.MustCompile(`^[A-Za-z0-9_-]{8,64}$`)

func New(log *slog.Logger, deps Checker, maxBody int64, timeout time.Duration, draining func() bool) http.Handler {
	router := chi.NewRouter()
	router.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			response := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			w = response
			id := r.Header.Get("X-Request-ID")
			if !validID.MatchString(id) {
				var b [16]byte
				if _, err := rand.Read(b[:]); err != nil {
					http.Error(w, "unavailable", 503)
					return
				}
				id = hex.EncodeToString(b[:])
			}
			ctx := context.WithValue(r.Context(), ctxKey{}, id)
			ctx = propagation.TraceContext{}.Extract(ctx, propagation.HeaderCarrier(r.Header))
			ctx, span := otel.Tracer("flow/http").Start(ctx, "http.request", trace.WithSpanKind(trace.SpanKindServer))
			defer span.End()
			r = r.WithContext(ctx)
			r.Body = http.MaxBytesReader(w, r.Body, maxBody)
			w.Header().Set("X-Request-ID", id)
			w.Header().Set("X-Content-Type-Options", "nosniff")
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
			// PR-00 só recebe GETs sem corpo. Futuras escritas devem decodificar via MaxBytesReader.
			defer func() {
				if recover() != nil {
					if response.Status() == 0 {
						Error(w, r, 500, "internal_error", "Erro interno")
					}
					log.ErrorContext(ctx, "http panic", "request_id", id)
				}
				status := response.Status()
				if status == 0 {
					status = 200
				}
				span.SetAttributes(attribute.Int("http.response.status_code", status))
				log.InfoContext(ctx, "http request", "method", r.Method, "status", status, "request_id", id, "trace_id", span.SpanContext().TraceID().String(), "duration_ms", time.Since(start).Milliseconds())
			}()
			next.ServeHTTP(w, r)
			// Não registrar URL, query, headers, corpo ou erro bruto de dependência.
		})
	})
	router.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.ContentLength > maxBody {
				Error(w, r, 413, "payload_too_large", "Corpo excede o limite")
				return
			}
			next.ServeHTTP(w, r)
		})
	})
	router.Get("/healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "alive"}) })
	router.Get("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if draining() {
			Error(w, r, 503, "not_ready", "Serviço indisponível")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), timeout)
		defer cancel()
		for _, ok := range deps.Check(ctx) {
			if !ok {
				Error(w, r, 503, "not_ready", "Dependências indisponíveis")
				return
			}
		}
		writeJSON(w, 200, map[string]string{"status": "ready"})
	})
	router.NotFound(func(w http.ResponseWriter, r *http.Request) { Error(w, r, 404, "not_found", "Recurso não encontrado") })
	router.MethodNotAllowed(func(w http.ResponseWriter, r *http.Request) {
		Error(w, r, 405, "method_not_allowed", "Método não permitido")
	})
	return router
}
