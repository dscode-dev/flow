package participation

import (
	"bytes"
	"testing"
)

func TestConfigBoundsAndDomainKey(t *testing.T) {
	c, err := ParseConfig(func(string) string { return "" }, bytes.Repeat([]byte{5}, 32))
	if err != nil || c.CheckinTTLSeconds != 120 || c.CheckinLeadMinutes != 30 || c.MutationMinute != 30 || len(c.Key) != 32 {
		t.Fatal("defaults", err)
	}
	for _, test := range []struct{ k, v string }{{"CHECKIN_TTL_SECONDS", "29"}, {"CHECKIN_TTL_SECONDS", "301"}, {"CHECKIN_LEAD_MINUTES", "-1"}, {"CHECKIN_LEAD_MINUTES", "121"}, {"PARTICIPATION_MUTATION_MINUTE", "121"}, {"CHECKIN_TTL_SECONDS", "NaN"}} {
		if _, err := ParseConfig(func(k string) string {
			if k == test.k {
				return test.v
			}
			return ""
		}, bytes.Repeat([]byte{5}, 32)); err == nil {
			t.Fatal("invalid bound", test.k)
		}
	}
	if _, err := ParseConfig(func(string) string { return "" }, nil); err == nil {
		t.Fatal("missing key accepted")
	}
	if bytes.Equal(c.Key, bytes.Repeat([]byte{5}, 32)) {
		t.Fatal("key not domain-separated")
	}
}
