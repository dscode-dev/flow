package identity

import (
	"encoding/hex"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	HMACKey                                                                                             []byte
	AccessTTL, SessionTTL, ChallengeTTL, RecentAuth, ResendCooldown                                     time.Duration
	OTPAttempts, SMSNumberHour, SMSOriginHour, SMSGlobalDay, SMSGlobalMinute, OriginMinute, MaxSessions int
	GoogleClientIDs, AppleClientIDs, PhoneRegions                                                       []string
	TwilioAccountSID, TwilioAuthToken, TwilioServiceSID                                                 string
}

func ParseConfig(get func(string) string) (Config, error) {
	c := Config{}
	key, err := hex.DecodeString(get("IDENTITY_HMAC_KEY"))
	if err != nil || len(key) != 32 {
		return c, fmt.Errorf("IDENTITY_HMAC_KEY deve conter 32 bytes em hexadecimal")
	}
	c.HMACKey = key
	for _, p := range []struct {
		key, def string
		dst      *time.Duration
		min, max time.Duration
	}{
		{"AUTH_ACCESS_TTL", "10m", &c.AccessTTL, time.Minute, 15 * time.Minute}, {"AUTH_SESSION_TTL", "720h", &c.SessionTTL, time.Hour, 90 * 24 * time.Hour},
		{"AUTH_CHALLENGE_TTL", "5m", &c.ChallengeTTL, time.Minute, 10 * time.Minute}, {"AUTH_RECENT_AUTH", "5m", &c.RecentAuth, time.Minute, 10 * time.Minute},
		{"AUTH_RESEND_COOLDOWN", "60s", &c.ResendCooldown, 30 * time.Second, 10 * time.Minute},
	} {
		v := get(p.key)
		if v == "" {
			v = p.def
		}
		d, e := time.ParseDuration(v)
		if e != nil || d < p.min || d > p.max {
			return c, fmt.Errorf("%s inválido", p.key)
		}
		*p.dst = d
	}
	for _, p := range []struct {
		key           string
		def, min, max int
		dst           *int
	}{
		{"AUTH_OTP_ATTEMPTS", 5, 1, 5, &c.OTPAttempts}, {"SMS_NUMBER_HOUR", 3, 1, 10, &c.SMSNumberHour}, {"SMS_ORIGIN_HOUR", 5, 1, 100, &c.SMSOriginHour},
		{"SMS_GLOBAL_DAY", 100, 1, 100000, &c.SMSGlobalDay}, {"SMS_GLOBAL_MINUTE", 10, 1, 1000, &c.SMSGlobalMinute}, {"AUTH_ORIGIN_MINUTE", 60, 1, 1000, &c.OriginMinute}, {"AUTH_MAX_SESSIONS", 10, 1, 20, &c.MaxSessions},
	} {
		v := get(p.key)
		n := p.def
		if v != "" {
			n, err = strconv.Atoi(v)
			if err != nil {
				return c, fmt.Errorf("%s inválido", p.key)
			}
		}
		if n < p.min || n > p.max {
			return c, fmt.Errorf("%s fora do limite", p.key)
		}
		*p.dst = n
	}
	list := func(v string) []string {
		out := []string{}
		for _, s := range strings.Split(v, ",") {
			if s = strings.TrimSpace(s); s != "" {
				out = append(out, s)
			}
		}
		return out
	}
	c.GoogleClientIDs = list(get("GOOGLE_CLIENT_IDS"))
	c.AppleClientIDs = list(get("APPLE_CLIENT_IDS"))
	c.PhoneRegions = list(get("SMS_ALLOWED_REGIONS"))
	if len(c.PhoneRegions) == 0 {
		c.PhoneRegions = []string{"BR"}
	}
	for _, v := range append(append([]string{}, c.GoogleClientIDs...), c.AppleClientIDs...) {
		if len(v) > 255 || strings.ContainsAny(v, " \t\r\n/*") {
			return c, fmt.Errorf("client ID inválido; não usar wildcard")
		}
	}
	for _, v := range c.PhoneRegions {
		if !regexp.MustCompile(`^[A-Z]{2}$`).MatchString(v) {
			return c, fmt.Errorf("SMS_ALLOWED_REGIONS inválido")
		}
	}
	c.TwilioAccountSID = get("TWILIO_ACCOUNT_SID")
	c.TwilioAuthToken = get("TWILIO_AUTH_TOKEN")
	c.TwilioServiceSID = get("TWILIO_VERIFY_SERVICE_SID")
	if c.TwilioAccountSID != "" || c.TwilioAuthToken != "" || c.TwilioServiceSID != "" {
		if !regexp.MustCompile(`^AC[0-9a-fA-F]{32}$`).MatchString(c.TwilioAccountSID) || len(c.TwilioAuthToken) < 16 || !regexp.MustCompile(`^VA[0-9a-fA-F]{32}$`).MatchString(c.TwilioServiceSID) {
			return c, fmt.Errorf("configuração Twilio incompleta ou inválida")
		}
	}
	return c, nil
}
