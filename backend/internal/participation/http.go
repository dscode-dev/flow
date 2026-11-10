package participation

import (
	"bytes"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strconv"
	"unicode/utf8"

	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/platform/httpapi"
	"github.com/go-chi/chi/v5"
)

type Handler struct {
	s    *Service
	auth *identityhttp.Handler
}

func NewHandler(s *Service, auth *identityhttp.Handler) *Handler { return &Handler{s, auth} }
func respond(w http.ResponseWriter, out any, err error, r *http.Request) {
	if err != nil {
		f := identity.SafeFailure(err)
		messages := map[string]string{
			"private_invitation_required": "Experiências privadas exigem convite individual.", "capacity_full": "Não há vagas disponíveis. A solicitação ou convite foi preservado.", "capacity_below_confirmed": "O limite não pode ser menor que as confirmações atuais.", "participation_transition": "Esta ação não está disponível na situação atual.", "version_conflict": "A configuração mudou. Atualize antes de salvar.", "precondition_required": "Informe a versão atual.", "idempotency_conflict": "Esta chave já foi utilizada para outra operação.", "invitation_unavailable": "Não foi possível enviar o convite para esse destinatário.", "invitation_expired": "O convite expirou.", "checkin_unavailable": "Check-in indisponível para esta participação ou horário.", "checkin_code_invalid": "Código inválido para esta experiência.", "checkin_code_expired": "Código expirado. Solicite um novo ao participante.", "checkin_code_used": "Este código já foi utilizado ou revogado.", "not_found": "Recurso indisponível ou sem acesso.", "rate_limited": "Aguarde antes de tentar novamente.", "onboarding_required": "Conclua seu perfil para participar.", "unauthorized": "Autenticação necessária.", "account_restricted": "Conta indisponível.", "invalid_request": "Requisição inválida."}
		message := messages[f.Code]
		if message == "" {
			message = "Operação temporariamente indisponível."
		}
		if f.Status == 429 {
			w.Header().Set("Retry-After", "60")
		}
		httpapi.Error(w, r, f.Status, f.Code, message)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(200)
	_ = json.NewEncoder(w).Encode(out)
}
func decode(w http.ResponseWriter, r *http.Request, out any, required ...string) bool {
	ct, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || ct != "application/json" {
		respond(w, nil, ErrInvalid, r)
		return false
	}
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
	if err != nil {
		httpapi.Error(w, r, 413, "payload_too_large", "Corpo excede o limite.")
		return false
	}
	b = bytes.TrimSpace(b)
	if len(b) == 0 || b[0] != '{' || !utf8.Valid(b) {
		respond(w, nil, ErrInvalid, r)
		return false
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(out) != nil || d.Decode(new(any)) != io.EOF {
		respond(w, nil, ErrInvalid, r)
		return false
	}
	// Reject duplicate keys and missing required properties before domain execution.
	keys := map[string]bool{}
	tokens := json.NewDecoder(bytes.NewReader(b))
	_, _ = tokens.Token()
	for tokens.More() {
		k, err := tokens.Token()
		if err != nil {
			respond(w, nil, ErrInvalid, r)
			return false
		}
		name, ok := k.(string)
		if !ok || keys[name] {
			respond(w, nil, ErrInvalid, r)
			return false
		}
		keys[name] = true
		var value json.RawMessage
		if tokens.Decode(&value) != nil {
			respond(w, nil, ErrInvalid, r)
			return false
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) && name != "capacity" {
			respond(w, nil, ErrInvalid, r)
			return false
		}
	}
	for _, k := range required {
		if !keys[k] {
			respond(w, nil, ErrInvalid, r)
			return false
		}
	}
	return true
}
func key(w http.ResponseWriter, r *http.Request) (string, bool) {
	k := r.Header.Get("Idempotency-Key")
	if !id(k).Valid {
		respond(w, nil, ErrInvalid, r)
		return "", false
	}
	return k, true
}
func query(raw string, fields ...string) (url.Values, int, error) {
	if len(raw) > 4096 {
		return nil, 0, ErrInvalid
	}
	q, err := url.ParseQuery(raw)
	if err != nil {
		return nil, 0, ErrInvalid
	}
	allowed := map[string]bool{"limit": true, "cursor": true}
	for _, f := range fields {
		allowed[f] = true
	}
	for k, v := range q {
		if !allowed[k] || len(v) != 1 || v[0] == "" {
			return nil, 0, ErrInvalid
		}
	}
	limit := 20
	if q.Has("limit") {
		limit, err = strconv.Atoi(q.Get("limit"))
		if err != nil || limit < 1 || limit > 50 {
			return nil, 0, ErrInvalid
		}
	}
	return q, limit, nil
}
func (h *Handler) Register(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(h.auth.Limited, h.auth.Protected)
		r.Get("/v1/me/agenda", func(w http.ResponseWriter, r *http.Request) {
			q, n, e := query(r.URL.RawQuery, "section")
			if e != nil {
				respond(w, nil, e, r)
				return
			}
			section := q.Get("section")
			if section == "" {
				section = "upcoming"
			}
			out, e := h.s.Agenda(r.Context(), identityhttp.Session(r), section, q.Get("cursor"), n)
			respond(w, out, e, r)
		})
		r.Get("/v1/experiences/{experienceId}/participation", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.s.Summary(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"))
			respond(w, out, e, r)
		})
		r.Get("/v1/experiences/{experienceId}/participation-settings", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.s.Settings(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"))
			if e == nil {
				w.Header().Set("ETag", out.ETag())
			}
			respond(w, out, e, r)
		})
		r.Put("/v1/experiences/{experienceId}/participation-settings", func(w http.ResponseWriter, r *http.Request) {
			var in SettingsInput
			if !decode(w, r, &in, "mode", "capacity") {
				return
			}
			out, e := h.s.Configure(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), r.Header.Get("If-Match"), in, httpapi.RequestID(r.Context()))
			if e == nil {
				w.Header().Set("ETag", out.ETag())
			}
			respond(w, out, e, r)
		})
		for _, method := range []string{"PUT", "DELETE"} {
			r.MethodFunc(method, "/v1/experiences/{experienceId}/interest", func(w http.ResponseWriter, r *http.Request) {
				k, ok := key(w, r)
				if !ok {
					return
				}
				var in struct{}
				if !decode(w, r, &in) {
					return
				}
				out, e := h.s.Interest(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), k, method == "PUT", httpapi.RequestID(r.Context()))
				respond(w, out, e, r)
			})
		}
		for _, action := range []string{"confirm", "request", "cancel"} {
			r.Post("/v1/experiences/{experienceId}/participation/"+action, func(w http.ResponseWriter, r *http.Request) {
				k, ok := key(w, r)
				if !ok {
					return
				}
				var in struct{}
				if !decode(w, r, &in) {
					return
				}
				out, e := h.s.Participate(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), k, action, httpapi.RequestID(r.Context()))
				respond(w, out, e, r)
			})
		}
		for _, kind := range []string{"participants", "invitations"} {
			r.Get("/v1/experiences/{experienceId}/"+kind, func(w http.ResponseWriter, r *http.Request) {
				q, n, e := query(r.URL.RawQuery, "state")
				if e != nil {
					respond(w, nil, e, r)
					return
				}
				out, e := h.s.Roster(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), kind, q.Get("state"), q.Get("cursor"), n)
				respond(w, out, e, r)
			})
		}
		for _, action := range []string{"approve", "decline", "remove", "block", "unblock"} {
			r.Post("/v1/experiences/{experienceId}/participants/{userId}/"+action, func(w http.ResponseWriter, r *http.Request) {
				k, ok := key(w, r)
				if !ok {
					return
				}
				var in struct {
					Reason string `json:"reason,omitempty"`
				}
				if !decode(w, r, &in) {
					return
				}
				out, e := h.s.Manage(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), chi.URLParam(r, "userId"), k, action, httpapi.RequestID(r.Context()), in.Reason)
				respond(w, out, e, r)
			})
		}
		r.Post("/v1/experiences/{experienceId}/invitations", func(w http.ResponseWriter, r *http.Request) {
			k, ok := key(w, r)
			if !ok {
				return
			}
			var in InvitationInput
			if !decode(w, r, &in) {
				return
			}
			out, e := h.s.Invite(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), k, in, httpapi.RequestID(r.Context()))
			respond(w, out, e, r)
		})
		for _, action := range []string{"accept", "decline", "revoke"} {
			r.Post("/v1/invitations/{invitationId}/"+action, func(w http.ResponseWriter, r *http.Request) {
				k, ok := key(w, r)
				if !ok {
					return
				}
				var in struct{}
				if !decode(w, r, &in) {
					return
				}
				out, e := h.s.RespondInvitation(r.Context(), identityhttp.Session(r), chi.URLParam(r, "invitationId"), k, action, httpapi.RequestID(r.Context()))
				respond(w, out, e, r)
			})
		}
		r.Post("/v1/experiences/{experienceId}/check-in-credential", func(w http.ResponseWriter, r *http.Request) {
			var in struct{}
			if !decode(w, r, &in) {
				return
			}
			out, e := h.s.IssueCredential(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), httpapi.RequestID(r.Context()))
			respond(w, out, e, r)
		})
		r.Post("/v1/experiences/{experienceId}/check-ins/validate", func(w http.ResponseWriter, r *http.Request) {
			k, ok := key(w, r)
			if !ok {
				return
			}
			var in struct {
				Code string `json:"code"`
			}
			if !decode(w, r, &in, "code") {
				return
			}
			out, e := h.s.ValidateCheckin(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), k, in.Code, httpapi.RequestID(r.Context()))
			respond(w, out, e, r)
		})
		r.Post("/v1/experiences/{experienceId}/check-ins/{userId}/revoke", func(w http.ResponseWriter, r *http.Request) {
			k, ok := key(w, r)
			if !ok {
				return
			}
			var in struct{}
			if !decode(w, r, &in) {
				return
			}
			out, e := h.s.RevokeCheckin(r.Context(), identityhttp.Session(r), chi.URLParam(r, "experienceId"), chi.URLParam(r, "userId"), k, httpapi.RequestID(r.Context()))
			respond(w, out, e, r)
		})
	})
}
