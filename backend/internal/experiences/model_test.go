package experiences

import (
	"math"
	"strings"
	"testing"
	"time"
)

func str(s string) *string { return &s }
func TestTemporalAndInputBoundaries(t *testing.T) {
	for _, zone := range []string{"America/Recife", "America/New_York", "Europe/Berlin", "Asia/Tokyo", "UTC"} {
		if _, e := normalized(Input{Timezone: str(zone)}); e != nil {
			t.Fatalf("IANA %s: %v", zone, e)
		}
	}
	for _, zone := range []string{"Local", "GMT-3", "not/a-zone", ""} {
		if _, e := normalized(Input{Timezone: str(zone)}); e == nil {
			t.Fatalf("accepted zone %q", zone)
		}
	}
	// Fall-back 01:30 occurs twice: distinct UTC instants preserve the real hour.
	start := time.Date(2026, 11, 1, 5, 30, 0, 0, time.UTC)
	end := start.Add(time.Hour)
	loc, _ := time.LoadLocation("America/New_York")
	if start.In(loc).Format("15:04") != end.In(loc).Format("15:04") {
		t.Fatal("DST fixture")
	}
	in, e := normalized(Input{StartsAt: &start, EndsAt: &end, Timezone: str("America/New_York")})
	if e != nil || in.EndsAt.Sub(*in.StartsAt) != time.Hour {
		t.Fatalf("DST lost %v", e)
	}
	midnight := time.Date(2026, 12, 31, 23, 30, 0, 0, time.UTC)
	next := midnight.Add(2 * time.Hour)
	if _, e = normalized(Input{StartsAt: &midnight, EndsAt: &next, Timezone: str("UTC")}); e != nil {
		t.Fatal(e)
	}
	same := start
	if _, e = normalized(Input{StartsAt: &start, EndsAt: &same}); e == nil {
		t.Fatal("zero duration")
	}
	if _, e = normalized(Input{Location: &Location{math.NaN(), 0}}); e == nil {
		t.Fatal("NaN")
	}
	if _, e = normalized(Input{Title: strings.Repeat("á", 121)}); e == nil {
		t.Fatal("rune limit")
	}
	if _, e = normalized(Input{Title: "bad\u202ename"}); e == nil {
		t.Fatal("bidi control")
	}
	in, e = normalized(Input{Title: "  Cafe\u0301  ", Location: &Location{-8.123456789, -34.1}})
	if e != nil || in.Title != "Café" || in.Location.Latitude != -8.123457 || in.Visibility != "PRIVATE" {
		t.Fatal("normalization")
	}
}
func TestTicketURLSafety(t *testing.T) {
	for _, raw := range []string{"https://tickets.example/path?q=abc", "https://example.com:443/"} {
		if !safeTicket(raw) {
			t.Errorf("rejected %q", raw)
		}
	}
	for _, raw := range []string{"javascript:alert(1)", "http://example.com", "https://user:pass@example.com/", "https://127.0.0.1/", "https://[::1]/", "https://localhost/", "https://example.com:8443/", "https://example.com/#secret", "https://evil.example\\@example.com/", "https://.example/", "https://example.com/\n", "//example.com"} {
		if safeTicket(raw) {
			t.Errorf("accepted %q", raw)
		}
	}
}
func TestPhaseAndImmutableFields(t *testing.T) {
	now := time.Now().UTC()
	start, end := now.Add(-time.Hour), now.Add(time.Hour)
	e := Experience{Status: "PUBLISHED", Input: Input{StartsAt: &start, EndsAt: &end}}
	phase(&e, now)
	if e.Phase == nil || *e.Phase != "LIVE" {
		t.Fatal("live")
	}
	phase(&e, end)
	if *e.Phase != "ENDED" {
		t.Fatal("end boundary")
	}
	a := Input{Visibility: "PRIVATE", StartsAt: &start}
	b := a
	b.Title = "Correction"
	if !protectedEqual(a, b) {
		t.Fatal("title correction")
	}
	b.Visibility = "PUBLIC"
	if protectedEqual(a, b) {
		t.Fatal("visibility widening")
	}
}
