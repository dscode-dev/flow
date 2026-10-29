package provider

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/golang-jwt/jwt/v5"
)

type Identity struct{ Subject, Nonce string }
type TokenVerifier interface {
	Verify(context.Context, string) (Identity, error)
}
type AppleEvent struct{ Subject, Type, ID string }
type AppleNotifications interface {
	Notification(context.Context, string) (AppleEvent, error)
}
type OIDC struct {
	verifier  *oidc.IDTokenVerifier
	keys      oidc.KeySet
	audiences []string
	issuer    string
	now       func() time.Time
}

func NewGoogle(ctx context.Context, aud []string) *OIDC {
	return newOIDC(ctx, "https://accounts.google.com", "https://www.googleapis.com/oauth2/v3/certs", aud)
}
func NewApple(ctx context.Context, aud []string) *OIDC {
	return newOIDC(ctx, "https://appleid.apple.com", "https://appleid.apple.com/auth/keys", aud)
}
func newOIDC(ctx context.Context, issuer, jwks string, aud []string) *OIDC {
	client := &http.Client{Transport: limitedTransport{http.DefaultTransport}, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	keys := oidc.NewRemoteKeySet(oidc.ClientContext(ctx, client), jwks)
	v := &OIDC{keys: keys, audiences: aud, issuer: issuer, now: time.Now}
	v.verifier = oidc.NewVerifier(issuer, keys, &oidc.Config{SkipClientIDCheck: true, SupportedSigningAlgs: []string{"RS256"}, Now: func() time.Time { return v.now() }})
	return v
}
func (v *OIDC) approved(aud []string, azp string) bool {
	approved := false
	for _, a := range aud {
		for _, allowed := range v.audiences {
			if subtle.ConstantTimeCompare([]byte(a), []byte(allowed)) == 1 {
				approved = true
			}
		}
	}
	if !approved || len(aud) == 0 {
		return false
	}
	if len(aud) > 1 && azp == "" {
		return false
	}
	if azp != "" {
		for _, a := range v.audiences {
			if a == azp {
				return true
			}
		}
		return false
	}
	return true
}
func (v *OIDC) Verify(ctx context.Context, raw string) (Identity, error) {
	if len(raw) > 16384 {
		return Identity{}, ErrRejected
	}
	tok, e := v.verifier.Verify(ctx, raw)
	if e != nil {
		return Identity{}, ErrRejected
	}
	var claims struct {
		Nonce     string `json:"nonce"`
		AZP       string `json:"azp"`
		NotBefore *int64 `json:"nbf"`
	}
	if e = tok.Claims(&claims); e != nil || !v.approved(tok.Audience, claims.AZP) || len(tok.Subject) == 0 || len(tok.Subject) > 255 || tok.IssuedAt.IsZero() || tok.IssuedAt.After(v.now().Add(30*time.Second)) || v.now().Sub(tok.IssuedAt) > 5*time.Minute || claims.Nonce == "" || len(claims.Nonce) > 256 {
		return Identity{}, ErrRejected
	}
	if claims.NotBefore != nil && *claims.NotBefore > v.now().Add(30*time.Second).Unix() {
		return Identity{}, ErrRejected
	}
	return Identity{tok.Subject, claims.Nonce}, nil
}
func (v *OIDC) Notification(ctx context.Context, raw string) (AppleEvent, error) {
	// Notificações Apple documentadas não contêm exp. A assinatura, iss/aud,
	// iat, jti e janela de entrega são validados separadamente do ID token.
	if v.issuer != "https://appleid.apple.com" || len(raw) > 16384 {
		return AppleEvent{}, ErrRejected
	}
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return AppleEvent{}, ErrRejected
	}
	header, e := base64.RawURLEncoding.DecodeString(parts[0])
	if e != nil {
		return AppleEvent{}, ErrRejected
	}
	var h struct {
		Alg string `json:"alg"`
	}
	if json.Unmarshal(header, &h) != nil || h.Alg != "RS256" {
		return AppleEvent{}, ErrRejected
	}
	payload, e := v.keys.VerifySignature(ctx, raw)
	if e != nil {
		return AppleEvent{}, ErrRejected
	}
	var c struct {
		Issuer   string           `json:"iss"`
		Audience jwt.ClaimStrings `json:"aud"`
		IAT      int64            `json:"iat"`
		EXP      int64            `json:"exp"`
		ID       string           `json:"jti"`
		Events   json.RawMessage  `json:"events"`
	}
	if json.Unmarshal(payload, &c) != nil || c.Issuer != v.issuer || !v.approved(c.Audience, "") || c.IAT > v.now().Add(30*time.Second).Unix() || c.IAT < v.now().Add(-7*24*time.Hour).Unix() || c.ID == "" || len(c.ID) > 255 || (c.EXP != 0 && c.EXP <= v.now().Unix()) {
		return AppleEvent{}, ErrRejected
	}
	var ev struct {
		Type    string `json:"type"`
		Subject string `json:"sub"`
		Time    int64  `json:"event_time"`
	}
	events := c.Events
	if len(events) > 0 && events[0] == '"' {
		var s string
		if json.Unmarshal(events, &s) != nil {
			return AppleEvent{}, ErrRejected
		}
		events = []byte(s)
	}
	if json.Unmarshal(events, &ev) != nil || ev.Subject == "" || len(ev.Subject) > 255 || ev.Time > v.now().Add(30*time.Second).Unix() || ev.Time < v.now().Add(-7*24*time.Hour).Unix() {
		return AppleEvent{}, ErrRejected
	}
	switch ev.Type {
	case "consent-revoked", "account-deleted", "email-enabled", "email-disabled":
	default:
		return AppleEvent{}, ErrRejected
	}
	return AppleEvent{ev.Subject, ev.Type, c.ID}, nil
}

type limitedTransport struct{ base http.RoundTripper }

func (t limitedTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	res, e := t.base.RoundTrip(r)
	if e == nil {
		res.Body = struct {
			io.Reader
			io.Closer
		}{io.LimitReader(res.Body, 1<<20), res.Body}
	}
	return res, e
}
