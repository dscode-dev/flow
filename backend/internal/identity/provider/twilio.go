package provider

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var ErrUnavailable = errors.New("provider unavailable")
var ErrRejected = errors.New("credential rejected")
var ErrLimited = errors.New("provider rate limit")

type SMS interface {
	Start(context.Context, string) (string, error)
	Check(context.Context, string, string) (bool, error)
}
type Twilio struct {
	client                        *http.Client
	base, account, token, service string
}

func NewTwilio(account, token, service string) *Twilio {
	return &Twilio{client: &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, base: "https://verify.twilio.com/v2", account: account, token: token, service: service}
}

type verification struct {
	SID    string `json:"sid"`
	Status string `json:"status"`
}

func (t *Twilio) post(ctx context.Context, path string, form url.Values) (verification, error) {
	var out verification
	req, e := http.NewRequestWithContext(ctx, http.MethodPost, t.base+"/Services/"+t.service+path, strings.NewReader(form.Encode()))
	if e != nil {
		return out, ErrUnavailable
	}
	req.SetBasicAuth(t.account, t.token)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	res, e := t.client.Do(req)
	if e != nil {
		return out, ErrUnavailable
	}
	defer res.Body.Close()
	if res.StatusCode == 429 {
		return out, ErrLimited
	}
	if res.StatusCode == 404 {
		return out, ErrRejected
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return out, ErrUnavailable
	}
	if e = json.NewDecoder(io.LimitReader(res.Body, 32768)).Decode(&out); e != nil || !regexp.MustCompile(`^VE[0-9a-fA-F]{32}$`).MatchString(out.SID) {
		return verification{}, ErrUnavailable
	}
	return out, nil
}
func (t *Twilio) Start(ctx context.Context, phone string) (string, error) {
	v, e := t.post(ctx, "/Verifications", url.Values{"To": {phone}, "Channel": {"sms"}, "RiskCheck": {"enable"}})
	if e != nil {
		return "", e
	}
	if v.Status != "pending" {
		return "", ErrUnavailable
	}
	return v.SID, nil
}
func (t *Twilio) Check(ctx context.Context, sid, code string) (bool, error) {
	if !regexp.MustCompile(`^VE[0-9a-fA-F]{32}$`).MatchString(sid) {
		return false, ErrRejected
	}
	v, e := t.post(ctx, "/VerificationCheck", url.Values{"VerificationSid": {sid}, "Code": {code}})
	if e != nil {
		return false, e
	}
	if v.SID != sid {
		return false, ErrRejected
	}
	switch v.Status {
	case "approved":
		return true, nil
	case "pending", "expired", "max_attempts_reached", "canceled", "deleted", "failed":
		return false, nil
	default:
		return false, ErrUnavailable
	}
}
