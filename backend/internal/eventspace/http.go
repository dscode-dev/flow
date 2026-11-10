// Package eventspace exposes the contextual boundary of Social. Publications,
// interactions, reports, uploads and streaming continue through the Social API.
package eventspace

import (
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/platform/httpapi"
	"flow.local/backend/internal/social"
	"github.com/go-chi/chi/v5"
	"net/http"
)

type Handler struct {
	s    *social.Service
	auth *identityhttp.Handler
}

func NewHandler(s *social.Service, a *identityhttp.Handler) *Handler { return &Handler{s, a} }
func (h *Handler) Register(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(h.auth.Limited, h.auth.Protected)
		r.Get("/v1/experiences/{experienceId}/space", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.s.SpaceSummary(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), httpapi.RequestID(r.Context()))
			social.Respond(w, out, e, r)
		})
		for _, sec := range []struct{ path, section string }{{"feed", "FEED"}, {"gallery", "GALLERY"}, {"participants", "PARTICIPANTS"}, {"reports", "REPORTS"}, {"hidden", "HIDDEN"}} {
			r.Get("/v1/experiences/{experienceId}/space/"+sec.path, func(w http.ResponseWriter, r *http.Request) {
				cursor, n, e := social.PageQuery(r)
				if e != nil {
					social.Respond(w, nil, e, r)
					return
				}
				out, e := h.s.SpaceList(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), sec.section, cursor, n, httpapi.RequestID(r.Context()))
				social.Respond(w, out, e, r)
			})
		}
		r.Post("/v1/experiences/{experienceId}/space/moderation", func(w http.ResponseWriter, r *http.Request) {
			var in social.SpaceModeration
			if !social.Decode(w, r, &in, "target_type", "target_id", "action", "reason") {
				return
			}
			out, e := h.s.SpaceModeration(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), r.Header.Get("Idempotency-Key"), in, httpapi.RequestID(r.Context()))
			social.Respond(w, out, e, r)
		})
	})
}
