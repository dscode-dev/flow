package experiences

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/httpapi"
	"github.com/go-chi/chi/v5"
)

type Handler struct {
	service *Service
	media   *media.Service
	auth    *identityhttp.Handler
}

func NewHandler(s *Service, m *media.Service, auth *identityhttp.Handler) *Handler {
	return &Handler{s, m, auth}
}
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func failure(w http.ResponseWriter, r *http.Request, err error) {
	f := identity.SafeFailure(err)
	messages := map[string]string{"invalid_request": "Requisição inválida.", "unauthorized": "Autenticação necessária.", "account_restricted": "Conta indisponível.", "onboarding_required": "Conclua a configuração da conta.", "not_found": "Recurso não encontrado.", "experience_invalid": "Confira os dados da experiência.", "invalid_transition": "Operação indisponível neste estado.", "protected_attributes": "Agenda, local e visibilidade publicados estão protegidos.", "version_conflict": "A experiência foi alterada. Atualize os dados.", "precondition_required": "Informe a versão atual da experiência.", "idempotency_conflict": "Chave já utilizada com outros dados.", "draft_limit": "Limite de rascunhos atingido.", "publishing_restricted": "Publicação indisponível para esta experiência ou conta.", "rate_limited": "Aguarde antes de tentar novamente.", "media_invalid": "Imagem inválida ou fora dos limites.", "media_not_ready": "Capa indisponível para associação.", "upload_not_pending": "Upload não está pendente.", "upload_expired": "Autorização de upload expirada.", "media_unavailable": "Armazenamento temporariamente indisponível.", "temporarily_unavailable": "Serviço temporariamente indisponível."}
	message := messages[f.Code]
	if message == "" {
		message = "Operação indisponível."
	}
	if f.Status == 429 {
		w.Header().Set("Retry-After", "60")
	}
	httpapi.Error(w, r, f.Status, f.Code, message)
}
func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	ct, _, e := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if e != nil || ct != "application/json" {
		failure(w, r, ErrInvalid)
		return false
	}
	raw, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 32768))
	var tooLarge *http.MaxBytesError
	if errors.As(e, &tooLarge) {
		httpapi.Error(w, r, 413, "payload_too_large", "Corpo excede o limite.")
		return false
	}
	raw = bytes.TrimSpace(raw)
	if e != nil || len(raw) == 0 || raw[0] != '{' || !utf8.Valid(raw) {
		failure(w, r, ErrInvalid)
		return false
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(dst) != nil {
		failure(w, r, ErrInvalid)
		return false
	}
	if in, ok := dst.(*Input); ok {
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &fields) != nil {
			failure(w, r, ErrInvalid)
			return false
		}
		for _, name := range []string{"title", "description", "visibility", "venue_name", "address"} {
			if value, present := fields[name]; present && bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
				failure(w, r, ErrInvalid)
				return false
			}
		}
		if _, present := fields["visibility"]; present && in.Visibility == "" {
			failure(w, r, ErrInvalid)
			return false
		}
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		failure(w, r, ErrInvalid)
		return false
	}
	return true
}
func expected(w http.ResponseWriter, r *http.Request) (int64, bool) {
	value := r.Header.Get("If-Match")
	if value == "" {
		failure(w, r, ErrPrecondition)
		return 0, false
	}
	if len(value) < 3 || value[0] != '"' || value[len(value)-1] != '"' {
		failure(w, r, ErrInvalid)
		return 0, false
	}
	n, e := strconv.ParseInt(value[1:len(value)-1], 10, 64)
	if e != nil || n < 1 || n == math.MaxInt64 || versionTag(n) != value {
		failure(w, r, ErrInvalid)
		return 0, false
	}
	return n, true
}
func writeExperience(w http.ResponseWriter, status int, out Experience) {
	w.Header().Set("ETag", versionTag(out.Version))
	respond(w, status, out)
}
func (h *Handler) Register(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(h.auth.Limited, h.auth.Protected)
		r.Get("/v1/experience-categories", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.service.Categories(r.Context())
			if e != nil {
				failure(w, r, e)
				return
			}
			respond(w, 200, map[string]any{"items": out})
		})
		r.Post("/v1/experiences", func(w http.ResponseWriter, r *http.Request) {
			var body Input
			if !decode(w, r, &body) {
				return
			}
			out, e := h.service.Create(r.Context(), identityhttp.Session(r), r.Header.Get("Idempotency-Key"), body, httpapi.RequestID(r.Context()))
			if e != nil {
				failure(w, r, e)
				return
			}
			w.Header().Set("Location", "/v1/experiences/"+out.ID)
			writeExperience(w, 201, out)
		})
		r.Get("/v1/experiences", func(w http.ResponseWriter, r *http.Request) { h.list(w, r, false) })
		r.Get("/v1/me/experiences", func(w http.ResponseWriter, r *http.Request) { h.list(w, r, true) })
		r.Get("/v1/experiences/{experienceId}", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.service.Get(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"))
			if e != nil {
				failure(w, r, e)
				return
			}
			writeExperience(w, 200, out)
		})
		r.Put("/v1/experiences/{experienceId}", func(w http.ResponseWriter, r *http.Request) {
			v, ok := expected(w, r)
			if !ok {
				return
			}
			var body Input
			if !decode(w, r, &body) {
				return
			}
			out, e := h.service.Update(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), v, body, httpapi.RequestID(r.Context()))
			if e != nil {
				failure(w, r, e)
				return
			}
			writeExperience(w, 200, out)
		})
		for path, target := range map[string]string{"publish": "PUBLISHED", "cancel": "CANCELLED", "archive": "ARCHIVED"} {
			r.Post("/v1/experiences/{experienceId}/"+path, func(w http.ResponseWriter, r *http.Request) {
				v, ok := expected(w, r)
				if !ok {
					return
				}
				var body struct{}
				if !decode(w, r, &body) {
					return
				}
				out, e := h.service.Transition(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), v, target, httpapi.RequestID(r.Context()))
				if e != nil {
					failure(w, r, e)
					return
				}
				writeExperience(w, 200, out)
			})
		}
		r.Get("/v1/experiences/{experienceId}/cover", func(w http.ResponseWriter, r *http.Request) {
			b, ct, e := h.service.Cover(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"))
			if e != nil {
				failure(w, r, e)
				return
			}
			w.Header().Set("Content-Type", ct)
			w.Header().Set("Content-Disposition", "inline")
			w.Header().Set("Content-Length", strconv.Itoa(len(b)))
			w.WriteHeader(200)
			_, _ = w.Write(b)
		})
		r.Post("/v1/media/uploads", func(w http.ResponseWriter, r *http.Request) {
			var body media.InitiateRequest
			if !decode(w, r, &body) {
				return
			}
			out, e := h.media.Initiate(r.Context(), identityhttp.Session(r), r.Header.Get("Idempotency-Key"), body, httpapi.RequestID(r.Context()))
			if e != nil {
				failure(w, r, e)
				return
			}
			respond(w, 201, out)
		})
		r.Post("/v1/media/uploads/{mediaId}/confirm", func(w http.ResponseWriter, r *http.Request) {
			var body struct{}
			if !decode(w, r, &body) {
				return
			}
			out, e := h.media.Confirm(r.Context(), identityhttp.Session(r), chi.URLParam(r, "mediaId"), httpapi.RequestID(r.Context()))
			if e != nil {
				failure(w, r, e)
				return
			}
			respond(w, 200, out)
		})
	})
}
func (h *Handler) list(w http.ResponseWriter, r *http.Request, own bool) {
	values := r.URL.Query()
	allowed := map[string]bool{"limit": true, "cursor": true}
	if own {
		allowed["status"] = true
	} else {
		for _, k := range []string{"category_id", "phase", "latitude", "longitude", "radius_m"} {
			allowed[k] = true
		}
	}
	for k, v := range values {
		if !allowed[k] || len(v) != 1 || strings.TrimSpace(v[0]) == "" {
			failure(w, r, ErrInvalid)
			return
		}
	}
	f := Filter{Status: values.Get("status"), Category: values.Get("category_id"), Phase: values.Get("phase"), Limit: 20}
	if v := values.Get("limit"); v != "" {
		n, e := strconv.ParseInt(v, 10, 32)
		if e != nil {
			failure(w, r, ErrInvalid)
			return
		}
		f.Limit = int32(n)
	}
	if values.Has("latitude") || values.Has("longitude") || values.Has("radius_m") {
		f.Nearby = true
		for _, p := range []struct {
			k   string
			dst *float64
		}{{"latitude", &f.Latitude}, {"longitude", &f.Longitude}, {"radius_m", &f.RadiusM}} {
			v, e := strconv.ParseFloat(values.Get(p.k), 64)
			if e != nil || math.IsNaN(v) || math.IsInf(v, 0) {
				failure(w, r, ErrInvalid)
				return
			}
			*p.dst = v
		}
	}
	out, e := h.service.List(r.Context(), identityhttp.Session(r), own, f, values.Get("cursor"))
	if e != nil {
		failure(w, r, e)
		return
	}
	respond(w, 200, out)
}
