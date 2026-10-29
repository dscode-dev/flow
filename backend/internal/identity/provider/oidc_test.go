package provider

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func fixtureKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	b, e := os.ReadFile("testdata/test-only-rsa.pem")
	if e != nil {
		t.Fatal(e)
	}
	k, e := jwt.ParseRSAPrivateKeyFromPEM(b)
	if e != nil {
		t.Fatal(e)
	}
	return k
}
func sign(t *testing.T, key *rsa.PrivateKey, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = "test-key"
	raw, e := tok.SignedString(key)
	if e != nil {
		t.Fatal(e)
	}
	return raw
}
func TestGoogleAndAppleSignedTokens(t *testing.T) {
	key := fixtureKey(t)
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]string{"kty": "RSA", "kid": "test-key", "use": "sig", "alg": "RS256", "n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())}}})
	}))
	defer server.Close()
	for _, issuer := range []string{"https://accounts.google.com", "https://appleid.apple.com"} {
		t.Run(issuer, func(t *testing.T) {
			verifier := newOIDC(context.Background(), issuer, server.URL, []string{"approved-client"})
			verifier.now = func() time.Time { return now }
			for _, tc := range []struct {
				name   string
				mutate func(jwt.MapClaims)
				good   bool
			}{
				{"valid", func(jwt.MapClaims) {}, true}, {"audience", func(c jwt.MapClaims) { c["aud"] = "other-app" }, false}, {"issuer", func(c jwt.MapClaims) { c["iss"] = "https://evil.invalid" }, false},
				{"expired", func(c jwt.MapClaims) { c["exp"] = now.Add(-time.Second).Unix() }, false}, {"future iat", func(c jwt.MapClaims) { c["iat"] = now.Add(time.Minute).Unix() }, false}, {"stale proof", func(c jwt.MapClaims) { c["iat"] = now.Add(-6 * time.Minute).Unix() }, false},
				{"future nbf", func(c jwt.MapClaims) { c["nbf"] = now.Add(time.Minute).Unix() }, false},
				{"missing expiry", func(c jwt.MapClaims) { delete(c, "exp") }, false}, {"missing iat", func(c jwt.MapClaims) { delete(c, "iat") }, false}, {"missing nonce", func(c jwt.MapClaims) { delete(c, "nonce") }, false}, {"azp", func(c jwt.MapClaims) { c["azp"] = "other-app" }, false}, {"multiple audiences without azp", func(c jwt.MapClaims) { c["aud"] = []string{"approved-client", "other-app"} }, false},
			} {
				t.Run(tc.name, func(t *testing.T) {
					c := jwt.MapClaims{"iss": issuer, "aud": "approved-client", "sub": "stable-subject", "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(), "nonce": "one-time-nonce"}
					tc.mutate(c)
					_, e := verifier.Verify(context.Background(), sign(t, key, c))
					if (e == nil) != tc.good {
						t.Fatalf("accepted=%v want=%v", e == nil, tc.good)
					}
				})
			}
			c := jwt.MapClaims{"iss": issuer, "aud": "approved-client", "sub": "subject", "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(), "nonce": "nonce"}
			raw := sign(t, key, c)
			parts := []byte(raw)
			if parts[len(parts)-10] == 'a' {
				parts[len(parts)-10] = 'b'
			} else {
				parts[len(parts)-10] = 'a'
			}
			if _, e := verifier.Verify(context.Background(), string(parts)); e == nil {
				t.Fatal("invalid signature accepted")
			}
			hs := jwt.NewWithClaims(jwt.SigningMethodHS256, c)
			raw, _ = hs.SignedString([]byte("not-a-provider-key"))
			if _, e := verifier.Verify(context.Background(), raw); e == nil {
				t.Fatal("algorithm substitution accepted")
			}
			if issuer == "https://appleid.apple.com" {
				notification := jwt.MapClaims{"iss": issuer, "aud": "approved-client", "iat": now.Unix(), "jti": "notification-1", "events": map[string]any{"type": "account-deleted", "sub": "stable-subject", "event_time": now.Unix()}}
				ev, e := verifier.Notification(context.Background(), sign(t, key, notification))
				if e != nil || ev.Type != "account-deleted" {
					t.Fatal("documented notification without exp rejected", e)
				}
				notification["aud"] = "other-app"
				if _, e = verifier.Notification(context.Background(), sign(t, key, notification)); e == nil {
					t.Fatal("foreign notification accepted")
				}
			}
		})
	}
}
