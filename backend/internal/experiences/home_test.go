package experiences

import (
	"bytes"
	"testing"
)

func TestHomeConfiguration(t *testing.T) {
	for _, tc := range []struct {
		key, value string
		valid      bool
	}{
		{"", "", true}, {"HOME_SECTION_LIMIT", "8", true}, {"HOME_SECTION_LIMIT", "9", false},
		{"HOME_SOON_HOURS", "168", true}, {"HOME_SOON_HOURS", "0", false}, {"HOME_SOON_HOURS", "169", false},
		{"HOME_RADIUS_M", "100000", true}, {"HOME_RADIUS_M", "999", false}, {"HOME_RADIUS_M", "100001", false},
	} {
		t.Run(tc.key+tc.value, func(t *testing.T) {
			c, err := ParseConfig(func(k string) string {
				if k == tc.key {
					return tc.value
				}
				return ""
			}, bytes.Repeat([]byte{1}, 32))
			if (err == nil) != tc.valid {
				t.Fatalf("validation: %v", err)
			}
			if tc.key == "" && (c.HomeLimit != 6 || c.HomeSoonHours != 48 || c.HomeRadiusM != 25000) {
				t.Fatal("defaults")
			}
		})
	}
}
