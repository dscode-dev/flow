package experiences

import (
	"bytes"
	"testing"
)

func TestRadarInputBounds(t *testing.T) {
	c, e := ParseConfig(func(string) string { return "" }, bytes.Repeat([]byte{1}, 32))
	if e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct {
		query string
		valid bool
	}{
		{"bbox=179,-1,-179,1&zoom=8", true}, {"bbox=-9,-1,-8,1&zoom=8", true},
		{"bbox=-180,-1,180,1&zoom=8", false}, {"bbox=0,-90,1,1&zoom=8", false}, {"bbox=0,-1,0,1&zoom=8", false},
		{"bbox=NaN,-1,1,1&zoom=8", false}, {"bbox=0,-1,1,1&zoom=23", false}, {"bbox=0,-1,1,1&zoom=1", false},
		{"bbox=0,-1,1,1&zoom=8&limit=0", false}, {"bbox=0,-1,1,1&zoom=8&limit=101", false},
		{"bbox=0,-1,1,1&zoom=8&visibility=PRIVATE", false}, {"bbox=0,-1,1,1&zoom=8&zoom=9", false},
		{"bbox=0,-1,1,1&zoom=8&latitude=0&longitude=0&radius_m=1000", true},
		{"bbox=0,-1,1,1&zoom=8&latitude=0", false},
		{"bbox=0,-1,1,1&zoom=8&from=2026-11-08T00:00:00Z&until=2026-11-09T00:00:00Z", true},
		{"bbox=0,-1,1,1&zoom=8&from=2026-11-08T00:00:00Z&until=2027-11-09T00:00:00Z", false},
	} {
		t.Run(tc.query, func(t *testing.T) {
			f, e := parseRadarQuery(tc.query)
			if e == nil {
				e = f.validate(c)
			}
			if (e == nil) != tc.valid {
				t.Fatalf("validation %v", e)
			}
		})
	}
}
