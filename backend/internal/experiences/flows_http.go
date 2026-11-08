package experiences

import (
	"io"
	"net/http"
	"strconv"
	"time"

	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/httpapi"
	"github.com/go-chi/chi/v5"
)

func (h *Handler) registerFlows(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(h.auth.Limited)
		r.Get("/v1/flows/{experienceId}/content", func(w http.ResponseWriter, r *http.Request) {
			q := r.URL.Query()
			if len(q) != 1 || len(q["ticket"]) != 1 || len(r.URL.RawQuery) > 2048 {
				failure(w, r, ErrInvalid)
				return
			}
			out, e := h.service.FlowContent(r.Context(), chi.URLParam(r, "experienceId"), q.Get("ticket"), r.Header.Get("Range"))
			if e != nil {
				failure(w, r, e)
				return
			}
			defer out.Body.Close()
			w.Header().Set("Content-Type", out.ContentType)
			w.Header().Set("Content-Length", strconv.FormatInt(out.Length, 10))
			w.Header().Set("Accept-Ranges", "bytes")
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Referrer-Policy", "no-referrer")
			status := 200
			if out.ContentRange != "" {
				status = 206
				w.Header().Set("Content-Range", out.ContentRange)
			}
			w.WriteHeader(status)
			_, _ = io.CopyN(w, out.Body, out.Length)
		})
	})
	r.Group(func(r chi.Router) {
		r.Use(h.auth.Limited, h.auth.Protected)
		for _, route := range []struct {
			path  string
			flows bool
		}{{"/v1/explore/experiences", false}, {"/v1/flows", true}} {
			r.Get(route.path, func(w http.ResponseWriter, r *http.Request) {
				start := time.Now()
				f, c, e := parseDiscovery(r.URL.RawQuery, h.service.config, route.flows)
				if e != nil {
					failure(w, r, e)
					return
				}
				var out any
				var count int
				if route.flows {
					v, err := h.service.Flows(r.Context(), identityhttp.Session(r), f, c)
					out, e, count = v, err, len(v.Items)
				} else {
					v, err := h.service.Explore(r.Context(), identityhttp.Session(r), f, c)
					out, e, count = v, err, len(v.Items)
				}
				if e != nil {
					failure(w, r, e)
					return
				}
				w.Header().Set("Cache-Control", "no-store")
				respond(w, 200, out)
				h.log.InfoContext(r.Context(), "discovery query", "flows", route.flows, "request_id", httpapi.RequestID(r.Context()), "duration_ms", time.Since(start).Milliseconds(), "returned", count)
			})
		}
		r.Get("/v1/flows/{experienceId}", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.service.Flow(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"))
			if e != nil {
				failure(w, r, e)
				return
			}
			w.Header().Set("Cache-Control", "no-store")
			respond(w, 200, out)
		})
		r.Get("/v1/experiences/{experienceId}/flow", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.service.Presentation(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"))
			if e != nil {
				failure(w, r, e)
				return
			}
			w.Header().Set("ETag", versionTag(out.Version))
			respond(w, 200, out)
		})
		r.Put("/v1/experiences/{experienceId}/flow", func(w http.ResponseWriter, r *http.Request) {
			var version int64
			if r.Header.Get("If-Match") != "\"0\"" {
				v, ok := expected(w, r)
				if !ok {
					return
				}
				version = v
			}
			var body PresentationInput
			if !decode(w, r, &body) {
				return
			}
			out, e := h.service.SavePresentation(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), version, body, httpapi.RequestID(r.Context()))
			if e != nil {
				failure(w, r, e)
				return
			}
			w.Header().Set("ETag", versionTag(out.Version))
			respond(w, 200, out)
		})
		r.Post("/v1/experiences/{experienceId}/flow/media", func(w http.ResponseWriter, r *http.Request) {
			var body media.InitiateRequest
			if !decode(w, r, &body) {
				return
			}
			out, e := h.media.InitiateFlow(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), r.Header.Get("Idempotency-Key"), body, httpapi.RequestID(r.Context()))
			if e != nil {
				failure(w, r, e)
				return
			}
			respond(w, 201, out)
		})
		r.Get("/v1/experiences/{experienceId}/flow/media/{mediaId}", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.media.FlowAsset(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), chi.URLParam(r, "mediaId"))
			if e != nil {
				failure(w, r, e)
				return
			}
			respond(w, 200, out)
		})
		r.Post("/v1/experiences/{experienceId}/flow/media/{mediaId}/confirm", func(w http.ResponseWriter, r *http.Request) {
			var body struct{}
			if !decode(w, r, &body) {
				return
			}
			out, e := h.media.ConfirmFlow(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), chi.URLParam(r, "mediaId"), httpapi.RequestID(r.Context()))
			if e != nil {
				failure(w, r, e)
				return
			}
			respond(w, 202, out)
		})
	})
}
