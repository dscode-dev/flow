//go:build integration

package integration

import (
	"context"
	"strings"
	"testing"

	"flow.local/backend/internal/identity"
)

func TestDevelopmentPhoneLogin(t *testing.T) {
	config, err := identity.ParseConfig(func(k string) string {
		switch k {
		case "IDENTITY_HMAC_KEY":
			return strings.Repeat("ab", 32)
		case "FLOW_ENV":
			return "development"
		case "AUTH_DEVELOPMENT_PHONE_ENABLED":
			return "true"
		case "AUTH_DEVELOPMENT_PHONE_NUMBER":
			return "+5511999999999"
		case "AUTH_DEVELOPMENT_SMS_CODE":
			return "123456"
		default:
			return ""
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, func(c *identity.Config) { *c = config })
	expect(t, h.request("POST", "/v1/auth/phone/challenges", "", map[string]string{"phone": "+5511988888888", "purpose": "login"}), 503)
	challenge := h.challenge(t, "PHONE", "login", "", "+5511999999999")
	body := map[string]any{"challenge_id": challenge.ID, "code": "000000", "device": identity.Device{Platform: "ios", AppVersion: "development-test"}}
	expect(t, h.request("POST", "/v1/auth/phone/verify", "", body), 401)
	if count(t, "SELECT count(*) FROM identity.users") != 0 {
		t.Fatal("account created before valid proof")
	}
	body["code"] = "123456"
	login := decode[identity.LoginResult](t, expect(t, h.request("POST", "/v1/auth/phone/verify", "", body), 200))
	if !login.User.OnboardingRequired || login.User.ID == "" || !strings.HasPrefix(login.Tokens.AccessToken, "fa_") {
		t.Fatal("normal identity session not issued")
	}
	expect(t, h.request("POST", "/v1/auth/phone/verify", "", body), 401)
	expect(t, h.request("GET", "/v1/me", login.Tokens.AccessToken, nil), 200)
	expect(t, h.request("POST", "/v1/auth/phone/challenges", login.Tokens.AccessToken, map[string]string{"phone": "+5511999999999", "purpose": "reauth"}), 503)
	expect(t, h.request("PATCH", "/v1/me/onboarding", login.Tokens.AccessToken, map[string]string{"display_name": "Conta de teste", "handle": "development_test"}), 200)
	rotated := decode[identity.LoginResult](t, expect(t, h.request("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": login.Tokens.RefreshToken}), 200))
	if rotated.User.OnboardingRequired {
		t.Fatal("onboarding not persisted")
	}
	expect(t, h.request("POST", "/v1/auth/logout", rotated.Tokens.AccessToken, map[string]any{}), 204)
	expect(t, h.request("GET", "/v1/me", rotated.Tokens.AccessToken, nil), 401)
	if smsCounter.Load() != 0 || checkCounter.Load() != 0 {
		t.Fatal("test phone contacted Twilio")
	}
	if strings.Contains(h.logs.String(), "123456") || strings.Contains(h.logs.String(), "5511999999999") {
		t.Fatal("test credentials logged")
	}
	var rawReference string
	if err = pool.QueryRow(context.Background(), "SELECT provider_reference FROM identity.challenges WHERE id=$1", challenge.ID).Scan(&rawReference); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(rawReference, "flow-dev-v1.") {
		t.Fatal("development delivery not used")
	}
}
