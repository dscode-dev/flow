package social

import (
	"bytes"
	"encoding/json"
	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/httpapi"
	"github.com/go-chi/chi/v5"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strconv"
	"unicode/utf8"
)

var ErrInvalid = identity.ErrInvalid

type Handler struct {
	s    *Service
	auth *identityhttp.Handler
}

func NewHandler(s *Service, a *identityhttp.Handler) *Handler { return &Handler{s, a} }
func respond(w http.ResponseWriter, out any, e error, r *http.Request) {
	if e != nil {
		f := identity.SafeFailure(e)
		if f.Status == 429 {
			w.Header().Set("Retry-After", "60")
		}
		message := map[string]string{"invalid_request": "Requisição inválida.", "not_found": "Conteúdo indisponível ou sem acesso.", "social_content_invalid": "Confira o conteúdo e os limites da publicação.", "version_conflict": "A publicação mudou. Atualize antes de editar.", "precondition_required": "Informe a versão atual.", "idempotency_conflict": "Esta tentativa já foi recebida com outros dados.", "rate_limited": "Aguarde antes de tentar novamente.", "account_restricted": "Conta indisponível para o Social.", "space_read_only": "Este espaço está em modo de leitura ou suas interações estão restritas."}[f.Code]
		if message == "" {
			message = "Não foi possível concluir a operação."
		}
		httpapi.Error(w, r, f.Status, f.Code, message)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(out)
}
func decode(w http.ResponseWriter, r *http.Request, out any, required ...string) bool {
	ct, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || ct != "application/json" {
		respond(w, nil, ErrInvalid, r)
		return false
	}
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 32768))
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
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) && name != "experience_id" {
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
func query(r *http.Request, feed bool) (string, string, int, error) {
	if len(r.URL.RawQuery) > 4096 {
		return "", "", 0, ErrInvalid
	}
	q, e := url.ParseQuery(r.URL.RawQuery)
	if e != nil {
		return "", "", 0, ErrInvalid
	}
	for k, v := range q {
		if len(v) != 1 || (k != "cursor" && k != "limit" && !(feed && k == "mode")) {
			return "", "", 0, ErrInvalid
		}
	}
	n := 20
	if q.Has("limit") {
		n, e = strconv.Atoi(q.Get("limit"))
		if e != nil || n < 1 || n > 50 {
			return "", "", 0, ErrInvalid
		}
	}
	mode := q.Get("mode")
	if mode == "" {
		mode = "DISCOVER"
	}
	if mode != "DISCOVER" && mode != "FOLLOWING" {
		return "", "", 0, ErrInvalid
	}
	return mode, q.Get("cursor"), n, nil
}
func (h *Handler) Register(r chi.Router) {
	r.With(h.auth.Limited).Get("/v1/social/posts/{postId}/media/{mediaId}/content", func(w http.ResponseWriter, r *http.Request) {
		q, e := url.ParseQuery(r.URL.RawQuery)
		if e != nil || len(q) != 1 || len(q["ticket"]) != 1 {
			respond(w, nil, ErrInvalid, r)
			return
		}
		stream, e := h.s.Content(r.Context(), chi.URLParam(r, "postId"), chi.URLParam(r, "mediaId"), q.Get("ticket"), r.Header.Get("Range"))
		if e != nil {
			respond(w, nil, e, r)
			return
		}
		defer stream.Body.Close()
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", stream.ContentType)
		w.Header().Set("Content-Length", strconv.FormatInt(stream.Length, 10))
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if stream.ContentRange != "" {
			w.Header().Set("Content-Range", stream.ContentRange)
			w.WriteHeader(206)
		}
		_, _ = io.Copy(w, stream.Body)
	})
	r.With(h.auth.Limited).Get("/v1/social/media/{mediaId}/content", func(w http.ResponseWriter, r *http.Request) {
		q, e := url.ParseQuery(r.URL.RawQuery)
		if e != nil || len(q) != 1 || len(q["ticket"]) != 1 {
			respond(w, nil, ErrInvalid, r)
			return
		}
		stream, e := h.s.Preview(r.Context(), chi.URLParam(r, "mediaId"), q.Get("ticket"), r.Header.Get("Range"))
		if e != nil {
			respond(w, nil, e, r)
			return
		}
		defer stream.Body.Close()
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", stream.ContentType)
		w.Header().Set("Content-Length", strconv.FormatInt(stream.Length, 10))
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if stream.ContentRange != "" {
			w.Header().Set("Content-Range", stream.ContentRange)
			w.WriteHeader(206)
		}
		_, _ = io.Copy(w, stream.Body)
	})
	r.Group(func(r chi.Router) {
		r.Use(h.auth.Limited, h.auth.Protected)
		r.Get("/v1/social/limits", func(w http.ResponseWriter, r *http.Request) { respond(w, h.s.Limits(), nil, r) })
		list := func(section, target string) http.HandlerFunc {
			return func(w http.ResponseWriter, r *http.Request) {
				mode, raw, n, e := query(r, section == "FEED")
				if e != nil {
					respond(w, nil, e, r)
					return
				}
				sec := section
				if sec == "FEED" {
					sec = mode
				}
				out, e := h.s.List(r.Context(), identityhttp.Session(r), sec, chi.URLParam(r, target), raw, n)
				respond(w, out, e, r)
			}
		}
		r.Get("/v1/social/experience-options", list("EXPERIENCES", ""))
		r.Get("/v1/social/feed", list("FEED", ""))
		r.Get("/v1/social/blocks", list("BLOCKS", ""))
		r.Get("/v1/social/profiles/{userId}", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.s.Profile(r.Context(), identityhttp.Session(r), chi.URLParam(r, "userId"))
			respond(w, out, e, r)
		})
		r.Get("/v1/social/profiles/{userId}/posts", list("PROFILE", "userId"))
		r.Get("/v1/social/profiles/{userId}/followers", list("FOLLOWERS", "userId"))
		r.Get("/v1/social/profiles/{userId}/following", list("PEOPLE_FOLLOWING", "userId"))
		r.Get("/v1/social/posts/{postId}", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.s.Post(r.Context(), identityhttp.Session(r), chi.URLParam(r, "postId"))
			respond(w, out, e, r)
		})
		r.Get("/v1/social/posts/{postId}/comments", list("COMMENTS", "postId"))
		r.Post("/v1/social/posts", func(w http.ResponseWriter, r *http.Request) {
			var in Input
			if !decode(w, r, &in, "context", "visibility", "body", "media_ids") {
				return
			}
			out, e := h.s.Create(r.Context(), identityhttp.Session(r), r.Header.Get("Idempotency-Key"), in, httpapi.RequestID(r.Context()))
			respond(w, out, e, r)
		})
		for _, op := range []struct{ method, path, action string }{{"PATCH", "/v1/social/posts/{postId}", "edit"}, {"DELETE", "/v1/social/posts/{postId}", "delete"}, {"PUT", "/v1/social/posts/{postId}/like", "like"}, {"DELETE", "/v1/social/posts/{postId}/like", "unlike"}, {"POST", "/v1/social/posts/{postId}/comments", "comment"}} {
			r.MethodFunc(op.method, op.path, func(w http.ResponseWriter, r *http.Request) {
				var in struct {
					Body string `json:"body"`
				}
				if op.action == "edit" || op.action == "comment" {
					if !decode(w, r, &in, "body") {
						return
					}
				} else {
					var empty struct{}
					if !decode(w, r, &empty) {
						return
					}
				}
				out, e := h.s.PostAction(r.Context(), identityhttp.Session(r), chi.URLParam(r, "postId"), r.Header.Get("Idempotency-Key"), op.action, in.Body, r.Header.Get("If-Match"), httpapi.RequestID(r.Context()))
				respond(w, out, e, r)
			})
		}
		r.Delete("/v1/social/posts/{postId}/comments/{commentId}", func(w http.ResponseWriter, r *http.Request) {
			var in struct{}
			if !decode(w, r, &in) {
				return
			}
			out, e := h.s.DeleteComment(r.Context(), identityhttp.Session(r), chi.URLParam(r, "postId"), chi.URLParam(r, "commentId"), r.Header.Get("Idempotency-Key"), httpapi.RequestID(r.Context()))
			respond(w, out, e, r)
		})
		for _, op := range []struct{ method, path, action string }{{"PUT", "/v1/social/profiles/{userId}/follow", "follow"}, {"DELETE", "/v1/social/profiles/{userId}/follow", "unfollow"}, {"PUT", "/v1/social/profiles/{userId}/block", "block"}, {"DELETE", "/v1/social/profiles/{userId}/block", "unblock"}} {
			r.MethodFunc(op.method, op.path, func(w http.ResponseWriter, r *http.Request) {
				var in struct{}
				if !decode(w, r, &in) {
					return
				}
				out, e := h.s.Relation(r.Context(), identityhttp.Session(r), chi.URLParam(r, "userId"), r.Header.Get("Idempotency-Key"), op.action, httpapi.RequestID(r.Context()))
				respond(w, out, e, r)
			})
		}
		r.Post("/v1/social/reports", func(w http.ResponseWriter, r *http.Request) {
			var in Report
			if !decode(w, r, &in, "target_type", "target_id", "reason") {
				return
			}
			out, e := h.s.Report(r.Context(), identityhttp.Session(r), r.Header.Get("Idempotency-Key"), in, httpapi.RequestID(r.Context()))
			respond(w, out, e, r)
		})
		r.Post("/v1/social/media", func(w http.ResponseWriter, r *http.Request) {
			var in media.InitiateRequest
			if !decode(w, r, &in, "content_type", "size_bytes") {
				return
			}
			out, e := h.s.media.InitiateSocial(r.Context(), identityhttp.Session(r), r.Header.Get("Idempotency-Key"), in, httpapi.RequestID(r.Context()))
			respond(w, out, e, r)
		})
		r.Get("/v1/social/media/{mediaId}", func(w http.ResponseWriter, r *http.Request) {
			out, e := h.s.OwnMedia(r.Context(), identityhttp.Session(r), chi.URLParam(r, "mediaId"))
			respond(w, out, e, r)
		})
		r.Post("/v1/social/media/{mediaId}/confirm", func(w http.ResponseWriter, r *http.Request) {
			var in struct{}
			if !decode(w, r, &in) {
				return
			}
			_, e := h.s.media.ConfirmSocial(r.Context(), identityhttp.Session(r), chi.URLParam(r, "mediaId"), httpapi.RequestID(r.Context()))
			if e != nil {
				respond(w, nil, e, r)
				return
			}
			out, e := h.s.OwnMedia(r.Context(), identityhttp.Session(r), chi.URLParam(r, "mediaId"))
			respond(w, out, e, r)
		})
	})
}

// Shared transport boundary for contextual Social modules; identical strict JSON/errors.
func Respond(w http.ResponseWriter, out any, e error, r *http.Request) { respond(w, out, e, r) }
func Decode(w http.ResponseWriter, r *http.Request, out any, required ...string) bool {
	return decode(w, r, out, required...)
}
func PageQuery(r *http.Request) (string, int, error) {
	_, raw, n, e := query(r, false)
	return raw, n, e
}
