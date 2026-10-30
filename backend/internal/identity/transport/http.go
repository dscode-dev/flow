package transport

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/httpapi"
	"github.com/go-chi/chi/v5"
)

type Handler struct{ service *identity.Service }
type sessionKey struct{}

func New(s *identity.Service) *Handler { return &Handler{s} }
func session(r *http.Request) *identity.Session {
	s, _ := r.Context().Value(sessionKey{}).(*identity.Session)
	return s
}

// Session returns the principal verified by Protected; never reads client IDs.
func Session(r *http.Request) *identity.Session { return session(r) }

// Protected reuses Identity's authoritative bearer/session/account checks.
func (h *Handler) Protected(next http.Handler) http.Handler { return h.protected(next) }

// Limited applies the same origin quota and request deadline across modules.
func (h *Handler) Limited(next http.Handler) http.Handler { return h.limited(next) }
func (h *Handler) meta(r *http.Request) identity.Metadata {
	return identity.Metadata{Origin: h.service.Origin(r.RemoteAddr), RequestID: httpapi.RequestID(r.Context())}
}
func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if value != nil {
		_ = json.NewEncoder(w).Encode(value)
	}
}
func fail(w http.ResponseWriter, r *http.Request, err error) {
	f := identity.SafeFailure(err)
	message := map[string]string{"invalid_request": "Requisição inválida.", "invalid_credential": "Credencial inválida ou expirada.", "unauthorized": "Autenticação necessária.", "account_restricted": "Conta indisponível.", "reauthentication_required": "Confirme sua identidade novamente.", "identity_conflict": "Identidade indisponível para vínculo.", "last_identity": "Mantenha pelo menos um método de autenticação disponível.", "handle_unavailable": "Nome de usuário indisponível.", "onboarding_already_completed": "Configuração inicial já concluída.", "session_limit": "Limite de sessões atingido.", "not_found": "Recurso não encontrado.", "rate_limited": "Aguarde antes de tentar novamente.", "provider_unavailable": "Método de autenticação temporariamente indisponível.", "temporarily_unavailable": "Serviço temporariamente indisponível."}[f.Code]
	if f.Status == 429 {
		w.Header().Set("Retry-After", "60")
	}
	httpapi.Error(w, r, f.Status, f.Code, message)
}
func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	media, _, e := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if e != nil || media != "application/json" {
		fail(w, r, identity.ErrInvalid)
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 32768)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	e = d.Decode(dst)
	if e == nil {
		var extra any
		if extraErr := d.Decode(&extra); extraErr != io.EOF {
			e = extraErr
			if e == nil {
				e = identity.ErrInvalid
			}
		}
	}
	if e != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(e, &tooLarge) {
			httpapi.Error(w, r, 413, "payload_too_large", "Corpo excede o limite.")
		} else {
			fail(w, r, identity.ErrInvalid)
		}
		return false
	}
	return true
}
func (h *Handler) limited(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		r = r.WithContext(ctx)
		if e := h.service.OriginLimit(ctx, h.meta(r)); e != nil {
			fail(w, r, e)
			return
		}
		next.ServeHTTP(w, r)
	})
}
func (h *Handler) authenticate(r *http.Request) (*identity.Session, error) {
	value := r.Header.Get("Authorization")
	if value == "" {
		return nil, nil
	}
	parts := strings.Split(value, " ")
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return nil, identity.ErrUnauthorized
	}
	return h.service.Authenticate(r.Context(), parts[1])
}
func (h *Handler) protected(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s, e := h.authenticate(r)
		if e == nil && s == nil {
			e = identity.ErrUnauthorized
		}
		if e != nil {
			fail(w, r, e)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), sessionKey{}, s)))
	})
}

func (h *Handler) Register(r chi.Router) {
	r.Route("/v1", func(r chi.Router) {
		r.Use(h.limited)
		r.Post("/auth/phone/challenges", func(w http.ResponseWriter, r *http.Request) { h.challenge(w, r, "PHONE") })
		r.Post("/auth/oidc/challenges", func(w http.ResponseWriter, r *http.Request) { h.challenge(w, r, "") })
		r.Post("/auth/phone/verify", func(w http.ResponseWriter, r *http.Request) { h.login(w, r, "PHONE") })
		r.Post("/auth/google", func(w http.ResponseWriter, r *http.Request) { h.login(w, r, "GOOGLE") })
		r.Post("/auth/apple", func(w http.ResponseWriter, r *http.Request) { h.login(w, r, "APPLE") })
		r.Post("/auth/refresh", func(w http.ResponseWriter, r *http.Request) {
			var body struct {
				RefreshToken string `json:"refresh_token"`
			}
			if !decode(w, r, &body) {
				return
			}
			out, e := h.service.Refresh(r.Context(), body.RefreshToken, h.meta(r))
			if e != nil {
				fail(w, r, e)
				return
			}
			respond(w, 200, out)
		})
		r.Post("/auth/apple/notifications", func(w http.ResponseWriter, r *http.Request) {
			var body struct {
				Payload string `json:"payload"`
			}
			if !decode(w, r, &body) {
				return
			}
			if e := h.service.AppleNotification(r.Context(), body.Payload, h.meta(r)); e != nil {
				fail(w, r, e)
				return
			}
			respond(w, 204, nil)
		})
		r.Group(func(r chi.Router) {
			r.Use(h.protected)
			r.Get("/me", func(w http.ResponseWriter, r *http.Request) {
				out, e := h.service.Me(r.Context(), session(r))
				if e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 200, out)
			})
			r.Patch("/me/onboarding", func(w http.ResponseWriter, r *http.Request) {
				var body struct {
					DisplayName string `json:"display_name"`
					Handle      string `json:"handle"`
				}
				if !decode(w, r, &body) {
					return
				}
				out, e := h.service.Onboarding(r.Context(), session(r), body.DisplayName, body.Handle, h.meta(r))
				if e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 200, out)
			})
			r.Get("/me/sessions", func(w http.ResponseWriter, r *http.Request) {
				out, e := h.service.Sessions(r.Context(), session(r))
				if e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 200, map[string]any{"items": out})
			})
			r.Delete("/me/sessions/{sessionId}", func(w http.ResponseWriter, r *http.Request) {
				if e := h.service.Revoke(r.Context(), session(r), chi.URLParam(r, "sessionId"), false, h.meta(r)); e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 204, nil)
			})
			r.Post("/me/sessions/revoke-all", func(w http.ResponseWriter, r *http.Request) {
				if e := h.service.Revoke(r.Context(), session(r), "", true, h.meta(r)); e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 204, nil)
			})
			r.Post("/auth/logout", func(w http.ResponseWriter, r *http.Request) {
				if e := h.service.Revoke(r.Context(), session(r), session(r).ID, false, h.meta(r)); e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 204, nil)
			})
			r.Post("/auth/reauthenticate", func(w http.ResponseWriter, r *http.Request) {
				var proof identity.Proof
				if !decode(w, r, &proof) {
					return
				}
				if e := h.service.Reauthenticate(r.Context(), session(r), proof, h.meta(r)); e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 204, nil)
			})
			r.Get("/me/identities", func(w http.ResponseWriter, r *http.Request) {
				out, e := h.service.Identities(r.Context(), session(r))
				if e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 200, map[string]any{"items": out})
			})
			r.Post("/me/identities/link", func(w http.ResponseWriter, r *http.Request) {
				var proof identity.Proof
				if !decode(w, r, &proof) {
					return
				}
				if e := h.service.Link(r.Context(), session(r), proof, h.meta(r)); e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 204, nil)
			})
			r.Delete("/me/identities/{identityId}", func(w http.ResponseWriter, r *http.Request) {
				if e := h.service.Unlink(r.Context(), session(r), chi.URLParam(r, "identityId"), h.meta(r)); e != nil {
					fail(w, r, e)
					return
				}
				respond(w, 204, nil)
			})
		})
	})
}
func (h *Handler) challenge(w http.ResponseWriter, r *http.Request, provider string) {
	var body identity.ChallengeRequest
	if provider != "" {
		var request struct {
			Phone   string `json:"phone"`
			Purpose string `json:"purpose"`
		}
		if !decode(w, r, &request) {
			return
		}
		body = identity.ChallengeRequest{Provider: provider, Phone: request.Phone, Purpose: request.Purpose}
	} else {
		var request struct {
			Provider string `json:"provider"`
			Purpose  string `json:"purpose"`
		}
		if !decode(w, r, &request) {
			return
		}
		body = identity.ChallengeRequest{Provider: request.Provider, Purpose: request.Purpose}
		if body.Provider != "GOOGLE" && body.Provider != "APPLE" {
			fail(w, r, identity.ErrInvalid)
			return
		}
	}
	s, e := h.authenticate(r)
	if e != nil {
		fail(w, r, e)
		return
	}
	out, e := h.service.Challenge(r.Context(), body, s, h.meta(r))
	if e != nil {
		fail(w, r, e)
		return
	}
	respond(w, 201, out)
}
func (h *Handler) login(w http.ResponseWriter, r *http.Request, provider string) {
	var challengeID, credential string
	var device identity.Device
	if provider == "PHONE" {
		var body struct {
			ChallengeID string          `json:"challenge_id"`
			Code        string          `json:"code"`
			Device      identity.Device `json:"device"`
		}
		if !decode(w, r, &body) {
			return
		}
		challengeID, credential, device = body.ChallengeID, body.Code, body.Device
	} else {
		var body struct {
			ChallengeID string          `json:"challenge_id"`
			IDToken     string          `json:"id_token"`
			Device      identity.Device `json:"device"`
		}
		if !decode(w, r, &body) {
			return
		}
		challengeID, credential, device = body.ChallengeID, body.IDToken, body.Device
	}
	out, e := h.service.Login(r.Context(), identity.Proof{Provider: provider, ChallengeID: challengeID, Credential: credential}, device, h.meta(r))
	if e != nil {
		fail(w, r, e)
		return
	}
	respond(w, 200, out)
}
