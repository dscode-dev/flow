package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTwilioAdapterBoundary(t *testing.T) {
	sid := "VE" + strings.Repeat("1", 32)
	status := 201
	checks := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, password, ok := r.BasicAuth()
		if !ok || user != "test-account" || password != "test-secret" {
			t.Error("missing provider auth")
		}
		_ = r.ParseForm()
		if strings.HasSuffix(r.URL.Path, "VerificationCheck") {
			checks++
			if r.Form.Get("VerificationSid") != sid {
				t.Error("unbound verification")
			}
		}
		w.WriteHeader(status)
		state := "pending"
		if r.Form.Get("Code") == "123456" {
			state = "approved"
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"sid": sid, "status": state, "message": "sensitive provider error"})
	}))
	defer server.Close()
	client := NewTwilio("test-account", "test-secret", "VA"+strings.Repeat("2", 32))
	client.base = server.URL
	got, e := client.Start(context.Background(), "+5511999999999")
	if e != nil || got != sid {
		t.Fatal(e)
	}
	approved, e := client.Check(context.Background(), sid, "000000")
	if e != nil || approved {
		t.Fatal("wrong code accepted")
	}
	approved, e = client.Check(context.Background(), sid, "123456")
	if e != nil || !approved {
		t.Fatal("approved code rejected")
	}
	for _, code := range []int{429, 500, 401, 404} {
		status = code
		_, e = client.Start(context.Background(), "+5511999999999")
		if e == nil || strings.Contains(e.Error(), "sensitive") {
			t.Fatal("provider failure not sanitized")
		}
	}
	if checks != 2 {
		t.Fatal("wrong verification call count")
	}
}
