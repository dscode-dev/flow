package identity

import (
	"strings"
	"testing"
)

func TestConfigAndNormalization(t *testing.T) {
	get := func(k string) string {
		if k == "IDENTITY_HMAC_KEY" {
			return strings.Repeat("ab", 32)
		}
		return ""
	}
	c, e := ParseConfig(get)
	if e != nil {
		t.Fatal(e)
	}
	if c.TwilioAccountSID != "" || len(c.GoogleClientIDs) != 0 || len(c.AppleClientIDs) != 0 {
		t.Fatal("provider unexpectedly enabled")
	}
	for _, tc := range []struct{ k, v string }{{"IDENTITY_HMAC_KEY", "short"}, {"AUTH_OTP_ATTEMPTS", "6"}, {"AUTH_ACCESS_TTL", "24h"}, {"TWILIO_AUTH_TOKEN", "partial-secret"}, {"GOOGLE_CLIENT_IDS", "*"}} {
		_, e = ParseConfig(func(k string) string {
			if k == tc.k {
				return tc.v
			}
			return get(k)
		})
		if e == nil {
			t.Fatal("invalid config accepted", tc.k)
		}
	}
	s := &Service{config: c}
	phone, e := s.normalizePhone("+55 (11) 99999-9999")
	if e != nil || phone != "+5511999999999" {
		t.Fatal("E.164 normalization", e)
	}
	if _, e = s.normalizePhone("11999999999"); e == nil {
		t.Fatal("ambiguous national format accepted")
	}
	if _, e = s.normalizePhone("+14155552671"); e == nil {
		t.Fatal("unapproved destination accepted")
	}
	if c.Origin("[2001:db8:1:2::1]:99") != c.Origin("[2001:db8:1:2::2]:99") {
		t.Fatal("IPv6 origin not bounded to /64")
	}
	if _, e = cleanLabel("name\u200b", 80); e == nil {
		t.Fatal("invisible character accepted")
	}
}
