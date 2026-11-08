package provider

import (
	"context"
	"strings"
	"testing"
)

type developmentFallback struct{ starts, checks int }

func (f *developmentFallback) Start(context.Context, string) (string, error) {
	f.starts++
	return "provider-reference", nil
}
func (f *developmentFallback) Check(context.Context, string, string) (bool, error) {
	f.checks++
	return false, nil
}

func TestDevelopmentSMSBoundaries(t *testing.T) {
	ctx := context.Background()
	fallback := &developmentFallback{}
	phone, code := "+5511999999999", "123456"
	key := []byte(strings.Repeat("k", 32))
	dev := NewDevelopmentSMS(phone, code, key, fallback)
	reference, err := dev.Start(ctx, phone)
	if err != nil || fallback.starts != 0 || strings.Contains(reference, phone) || strings.Contains(reference, code) {
		t.Fatal("development delivery boundary")
	}
	if ok, err := dev.Check(ctx, reference, "000000"); err != nil || ok {
		t.Fatal("wrong code accepted")
	}
	// Restart preserves references without persisting phone/code in the challenge.
	restarted := NewDevelopmentSMS(phone, code, key, fallback)
	if ok, err := restarted.Check(ctx, reference, code); err != nil || !ok {
		t.Fatal("matching code rejected")
	}
	for _, other := range []*DevelopmentSMS{
		NewDevelopmentSMS("+5511988888888", code, key, nil),
		NewDevelopmentSMS(phone, "654321", key, nil),
		NewDevelopmentSMS(phone, code, []byte(strings.Repeat("j", 32)), nil),
	} {
		if ok, _ := other.Check(ctx, reference, code); ok {
			t.Fatal("reference accepted with different configuration")
		}
	}
	if ok, _ := dev.Check(ctx, reference+"tamper", code); ok {
		t.Fatal("tampered reference accepted")
	}
	_, _ = dev.Start(ctx, "+5511988888888")
	_, _ = dev.Check(ctx, "provider-reference", code)
	if fallback.starts != 1 || fallback.checks != 1 {
		t.Fatal("fallback not isolated")
	}
	isolated := NewDevelopmentSMS(phone, code, key, nil)
	if _, err := isolated.Start(ctx, "+5511988888888"); err != ErrUnavailable {
		t.Fatal("unconfigured number accepted")
	}
	if ok, _ := isolated.Check(ctx, "VE"+strings.Repeat("0", 32), code); ok {
		t.Fatal("external reference accepted with test code")
	}
}
