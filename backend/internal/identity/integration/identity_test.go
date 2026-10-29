//go:build integration

package integration

import (
	"bytes"
	"context"
	"crypto/rsa"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/platform/httpapi"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/legacy"
	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/redis/go-redis/v9"
)

var pool *pgxpool.Pool
var key *rsa.PrivateKey
var contract routers.Router
var upstream *httptest.Server
var smsCounter atomic.Int64
var checkCounter atomic.Int64
var failDelivery atomic.Bool
var transport http.RoundTripper

type reroute struct{}

func (reroute) RoundTrip(r *http.Request) (*http.Response, error) {
	switch r.URL.Hostname() {
	case "verify.twilio.com", "www.googleapis.com", "appleid.apple.com":
		copy := r.Clone(r.Context())
		u := *r.URL
		target, _ := url.Parse(upstream.URL)
		u.Scheme = target.Scheme
		u.Host = target.Host
		copy.URL = &u
		return transport.RoundTrip(copy)
	default:
		return transport.RoundTrip(r)
	}
}
func TestMain(m *testing.M) {
	dsn := os.Getenv("FLOW_IDENTITY_TEST_DATABASE_URL")
	u, e := url.Parse(dsn)
	if e != nil || u.Path != "/flow_identity_test" {
		fmt.Fprintln(os.Stderr, "Use make identity-test; exige banco isolado flow_identity_test.")
		os.Exit(1)
	}
	db, e := sql.Open("pgx", dsn)
	if e != nil {
		panic(e)
	}
	if e = goose.SetDialect("postgres"); e != nil {
		panic(e)
	}
	if e = goose.DownTo(db, "../../../migrations", 0); e != nil {
		panic(e)
	}
	if e = goose.Up(db, "../../../migrations"); e != nil {
		panic(e)
	}
	_ = db.Close()
	pool, e = pgxpool.New(context.Background(), dsn)
	if e != nil {
		panic(e)
	}
	rc, e := redis.ParseURL(os.Getenv("FLOW_IDENTITY_TEST_REDIS_URL"))
	if e != nil {
		panic(e)
	}
	rc.DialTimeout = time.Second
	rc.MaxRetries = -1
	client := redis.NewClient(rc)
	c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	if client.Ping(c).Err() == nil {
		panic("teste exige Redis realmente indisponível")
	}
	cancel()
	_ = client.Close()
	b, e := os.ReadFile("../provider/testdata/test-only-rsa.pem")
	if e != nil {
		panic(e)
	}
	key, e = jwt.ParseRSAPrivateKeyFromPEM(b)
	if e != nil {
		panic(e)
	}
	doc, e := openapi3.NewLoader().LoadFromFile("../../../../contracts/openapi/flow.yaml")
	if e != nil {
		panic(e)
	}
	contract, e = legacy.NewRouter(doc)
	if e != nil {
		panic(e)
	}
	upstream = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/certs") || r.URL.Path == "/auth/keys" {
			_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]string{"kty": "RSA", "kid": "test-key", "alg": "RS256", "use": "sig", "n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())}}})
			return
		}
		if failDelivery.Load() {
			w.WriteHeader(500)
			_, _ = w.Write([]byte(`{"message":"sensitive-provider-debug"}`))
			return
		}
		_ = r.ParseForm()
		status, sid := "pending", r.Form.Get("VerificationSid")
		if strings.HasSuffix(r.URL.Path, "VerificationCheck") {
			checkCounter.Add(1)
			if r.Form.Get("Code") == "123456" {
				status = "approved"
			}
		} else {
			sid = fmt.Sprintf("VE%032x", smsCounter.Add(1))
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"sid": sid, "status": status})
	}))
	transport = http.DefaultTransport
	http.DefaultTransport = reroute{}
	code := m.Run()
	http.DefaultTransport = transport
	upstream.Close()
	pool.Close()
	os.Exit(code)
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}
func (b *lockedBuffer) String() string { b.mu.Lock(); defer b.mu.Unlock(); return b.b.String() }

type dbChecker struct{}

func (dbChecker) Check(ctx context.Context) map[string]bool {
	return map[string]bool{"postgres": pool.Ping(ctx) == nil}
}

type harness struct {
	server *httptest.Server
	logs   *lockedBuffer
}

func newHarness(t *testing.T, alter func(*identity.Config)) *harness {
	t.Helper()
	_, e := pool.Exec(context.Background(), `TRUNCATE identity.users,identity.rate_limits,identity.provider_notifications CASCADE; DELETE FROM integration.outbox`)
	if e != nil {
		t.Fatal(e)
	}
	smsCounter.Store(0)
	checkCounter.Store(0)
	failDelivery.Store(false)
	c, e := identity.ParseConfig(func(k string) string {
		switch k {
		case "IDENTITY_HMAC_KEY":
			return strings.Repeat("ab", 32)
		case "TWILIO_ACCOUNT_SID":
			return "AC" + strings.Repeat("1", 32)
		case "TWILIO_AUTH_TOKEN":
			return "test-only-not-a-provider-secret"
		case "TWILIO_VERIFY_SERVICE_SID":
			return "VA" + strings.Repeat("2", 32)
		case "GOOGLE_CLIENT_IDS":
			return "google-client"
		case "APPLE_CLIENT_IDS":
			return "com.example.flow.test"
		default:
			return ""
		}
	})
	if e != nil {
		t.Fatal(e)
	}
	if alter != nil {
		alter(&c)
	}
	service := identity.NewService(context.Background(), pool, c)
	handler := identityhttp.New(service)
	logs := &lockedBuffer{}
	server := httptest.NewServer(httpapi.New(slog.New(slog.NewJSONHandler(logs, nil)), dbChecker{}, 32768, time.Second, func() bool { return false }, handler.Register))
	t.Cleanup(server.Close)
	return &harness{server, logs}
}

type result struct {
	status int
	body   []byte
	err    error
}

func (h *harness) request(method, path, access string, body any) result {
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	req, e := http.NewRequest(method, h.server.URL+path, bytes.NewReader(raw))
	if e != nil {
		return result{err: e}
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if access != "" {
		req.Header.Set("Authorization", "Bearer "+access)
	}
	response, e := h.server.Client().Do(req)
	if e != nil {
		return result{err: e}
	}
	defer response.Body.Close()
	b, e := io.ReadAll(response.Body)
	if e != nil {
		return result{err: e}
	}
	// Validar resposta real contra contrato, inclusive envelopes de erro.
	req.URL.Scheme = ""
	req.URL.Host = ""
	route, params, e := contract.FindRoute(req)
	if e == nil {
		e = openapi3filter.ValidateResponse(context.Background(), &openapi3filter.ResponseValidationInput{RequestValidationInput: &openapi3filter.RequestValidationInput{Request: req, PathParams: params, Route: route}, Status: response.StatusCode, Header: response.Header, Body: io.NopCloser(bytes.NewReader(b))})
	}
	if e != nil && response.StatusCode == 404 {
		// Uma rota deliberadamente inexistente não tem operação OpenAPI.
		var envelope httpapi.Envelope
		e = json.Unmarshal(b, &envelope)
		if e == nil && (envelope.Error.Code != "not_found" || envelope.Error.RequestID == "") {
			e = fmt.Errorf("invalid unknown-route envelope")
		}
	}
	return result{response.StatusCode, b, e}
}
func expect(t *testing.T, r result, status int) []byte {
	t.Helper()
	if r.err != nil {
		t.Fatal(r.err)
	}
	if r.status != status {
		t.Fatalf("expected %d got %d: %s", status, r.status, r.body)
	}
	return r.body
}
func decode[T any](t *testing.T, b []byte) T {
	t.Helper()
	var out T
	if e := json.Unmarshal(b, &out); e != nil {
		t.Fatal(e)
	}
	return out
}
func (h *harness) challenge(t *testing.T, provider, purpose, access, phone string) identity.Challenge {
	t.Helper()
	path := "/v1/auth/oidc/challenges"
	body := map[string]string{"provider": provider, "purpose": purpose}
	if provider == "PHONE" {
		path = "/v1/auth/phone/challenges"
		delete(body, "provider")
		body["phone"] = phone
	}
	return decode[identity.Challenge](t, expect(t, h.request("POST", path, access, body), 201))
}
func token(t *testing.T, provider, subject, nonce string) string {
	t.Helper()
	issuer, aud := "https://accounts.google.com", "google-client"
	if provider == "APPLE" {
		issuer, aud = "https://appleid.apple.com", "com.example.flow.test"
	}
	claims := jwt.MapClaims{"iss": issuer, "aud": aud, "sub": subject, "nonce": nonce, "iat": time.Now().Unix(), "exp": time.Now().Add(5 * time.Minute).Unix(), "email": "same@privaterelay.appleid.com"}
	return signed(t, claims)
}
func signed(t *testing.T, c jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, c)
	tok.Header["kid"] = "test-key"
	raw, e := tok.SignedString(key)
	if e != nil {
		t.Fatal(e)
	}
	return raw
}
func (h *harness) login(t *testing.T, provider, subject string) identity.LoginResult {
	t.Helper()
	c := h.challenge(t, provider, "login", "", "+5511999999999")
	path, field, credential := "/v1/auth/google", "id_token", token(t, provider, subject, c.Nonce)
	if provider == "APPLE" {
		path = "/v1/auth/apple"
	}
	if provider == "PHONE" {
		path, field, credential = "/v1/auth/phone/verify", "code", "123456"
	}
	return decode[identity.LoginResult](t, expect(t, h.request("POST", path, "", map[string]any{"challenge_id": c.ID, field: credential, "device": identity.Device{Platform: "ios", AppVersion: "0.1.0", Label: "Teste"}}), 200))
}
func execSQL(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, e := pool.Exec(context.Background(), sql, args...); e != nil {
		t.Fatal(e)
	}
}
func count(t *testing.T, sql string, args ...any) int {
	t.Helper()
	var n int
	if e := pool.QueryRow(context.Background(), sql, args...).Scan(&n); e != nil {
		t.Fatal(e)
	}
	return n
}

func TestRegistrationSessionOnboardingAndPrivacy(t *testing.T) {
	h := newHarness(t, nil)
	login := h.login(t, "GOOGLE", "subject-a")
	if !login.User.OnboardingRequired {
		t.Fatal("missing onboarding state")
	}
	if count(t, "SELECT count(*) FROM identity.auth_identities WHERE provider='PHONE'") != 0 {
		t.Fatal("Google must not require phone")
	}
	expect(t, h.request("GET", "/v1/me", login.Tokens.AccessToken, nil), 200)
	body := map[string]string{"display_name": "  Pessoa de Teste  ", "handle": "  Pessoa_Teste  "}
	out := decode[identity.Me](t, expect(t, h.request("PATCH", "/v1/me/onboarding", login.Tokens.AccessToken, body), 200))
	if out.OnboardingRequired || out.Profile.Handle == nil || *out.Profile.Handle != "pessoa_teste" {
		t.Fatal("normalization/onboarding failed")
	}
	expect(t, h.request("PATCH", "/v1/me/onboarding", login.Tokens.AccessToken, body), 200)
	expect(t, h.request("PATCH", "/v1/me/onboarding", login.Tokens.AccessToken, map[string]string{"display_name": "Outra", "handle": "outro_handle"}), 409)
	again := h.login(t, "GOOGLE", "subject-a")
	if again.User.ID != login.User.ID {
		t.Fatal("duplicate internal account")
	}
	other := h.login(t, "APPLE", "subject-a")
	if other.User.ID == login.User.ID {
		t.Fatal("email or subject cross-provider auto-merge")
	}
	expect(t, h.request("PATCH", "/v1/me/onboarding", other.Tokens.AccessToken, body), 409)
	expect(t, h.request("PATCH", "/v1/me/onboarding", other.Tokens.AccessToken, map[string]string{"display_name": "Outra", "handle": "ADMIN"}), 409)
	if strings.Contains(h.logs.String(), login.Tokens.AccessToken) || strings.Contains(h.logs.String(), login.Tokens.RefreshToken) {
		t.Fatal("session secret logged")
	}
	if count(t, "SELECT count(*) FROM identity.refresh_credentials WHERE octet_length(credential_hash)<>32") != 0 {
		t.Fatal("refresh not hashed")
	}
	if count(t, "SELECT count(*) FROM integration.outbox WHERE event_type='identity.user.created'") != 2 {
		t.Fatal("transactional events missing")
	}
}

func TestConcurrentRegistrationAndChallengeReplay(t *testing.T) {
	h := newHarness(t, nil)
	const n = 6
	requests := make([]map[string]any, n)
	for i := range n {
		c := h.challenge(t, "GOOGLE", "login", "", "")
		requests[i] = map[string]any{"challenge_id": c.ID, "id_token": token(t, "GOOGLE", "concurrent-subject", c.Nonce), "device": identity.Device{Platform: "android", AppVersion: "0.1.0"}}
	}
	ready := make(chan struct{})
	results := make(chan result, n)
	for i := range n {
		go func() { <-ready; results <- h.request("POST", "/v1/auth/google", "", requests[i]) }()
	}
	close(ready)
	user := ""
	for range n {
		out := decode[identity.LoginResult](t, expect(t, <-results, 200))
		if user != "" && user != out.User.ID {
			t.Fatal("concurrent identity registered twice")
		}
		user = out.User.ID
	}
	if count(t, "SELECT count(*) FROM identity.users") != 1 || count(t, "SELECT count(*) FROM identity.auth_identities") != 1 {
		t.Fatal("uniqueness failed")
	}
	expect(t, h.request("POST", "/v1/auth/google", "", requests[0]), 401)
}

func TestOTPAtomicConsumptionAndAbuseRules(t *testing.T) {
	t.Run("single use concurrent", func(t *testing.T) {
		h := newHarness(t, nil)
		c := h.challenge(t, "PHONE", "login", "", "+5511999999999")
		body := map[string]any{"challenge_id": c.ID, "code": "123456", "device": identity.Device{Platform: "android", AppVersion: "0.1.0"}}
		results := make(chan result, 5)
		for range 5 {
			go func() { results <- h.request("POST", "/v1/auth/phone/verify", "", body) }()
		}
		success := 0
		for range 5 {
			r := <-results
			if r.status == 200 {
				success++
				expect(t, r, 200)
			} else {
				expect(t, r, 401)
			}
		}
		if success != 1 || checkCounter.Load() != 1 {
			t.Fatal("OTP consumed more than once")
		}
		if count(t, "SELECT count(*) FROM identity.challenges WHERE subject_ref LIKE '%5511999999999%'") != 0 {
			t.Fatal("plaintext phone persisted")
		}
	})
	t.Run("expiration and attempts", func(t *testing.T) {
		h := newHarness(t, nil)
		c := h.challenge(t, "PHONE", "login", "", "+5511988888888")
		execSQL(t, "UPDATE identity.challenges SET expires_at=now()-interval '1 second' WHERE id=$1", c.ID)
		body := map[string]any{"challenge_id": c.ID, "code": "123456", "device": identity.Device{Platform: "ios", AppVersion: "0.1.0"}}
		expect(t, h.request("POST", "/v1/auth/phone/verify", "", body), 401)
		if checkCounter.Load() != 0 {
			t.Fatal("expired proof reached provider")
		}
		c = h.challenge(t, "PHONE", "login", "", "+5511977777777")
		body["challenge_id"] = c.ID
		body["code"] = "000000"
		for range 5 {
			expect(t, h.request("POST", "/v1/auth/phone/verify", "", body), 401)
		}
		body["code"] = "123456"
		expect(t, h.request("POST", "/v1/auth/phone/verify", "", body), 401)
		if count(t, "SELECT attempts FROM identity.challenges WHERE id=$1", c.ID) != 5 || checkCounter.Load() != 5 {
			t.Fatal("attempt exhaustion failed")
		}
	})
	t.Run("resend cooldown and superseding", func(t *testing.T) {
		h := newHarness(t, nil)
		c := h.challenge(t, "PHONE", "login", "", "+5511999999999")
		body := map[string]string{"phone": "+5511999999999", "purpose": "login"}
		expect(t, h.request("POST", "/v1/auth/phone/challenges", "", body), 429)
		execSQL(t, "UPDATE identity.challenges SET created_at=now()-interval '61 seconds' WHERE id=$1", c.ID)
		expect(t, h.request("POST", "/v1/auth/phone/challenges", "", body), 201)
		expect(t, h.request("POST", "/v1/auth/phone/verify", "", map[string]any{"challenge_id": c.ID, "code": "123456", "device": identity.Device{Platform: "ios", AppVersion: "0.1.0"}}), 401)
	})
	t.Run("financial global cap and failed delivery", func(t *testing.T) {
		h := newHarness(t, func(c *identity.Config) { c.SMSGlobalDay = 1 })
		failDelivery.Store(true)
		expect(t, h.request("POST", "/v1/auth/phone/challenges", "", map[string]string{"phone": "+5511999999999", "purpose": "login"}), 503)
		failDelivery.Store(false)
		expect(t, h.request("POST", "/v1/auth/phone/challenges", "", map[string]string{"phone": "+5511988888888", "purpose": "login"}), 429)
		if count(t, "SELECT count(*) FROM identity.challenges WHERE status='failed'") != 1 {
			t.Fatal("delivery failure not persisted")
		}
	})
	t.Run("origin limit persists without Redis", func(t *testing.T) {
		h := newHarness(t, func(c *identity.Config) { c.OriginMinute = 2 })
		for range 2 {
			expect(t, h.request("POST", "/v1/auth/oidc/challenges", "", map[string]string{"provider": "GOOGLE", "purpose": "login"}), 201)
		}
		expect(t, h.request("POST", "/v1/auth/oidc/challenges", "", map[string]string{"provider": "GOOGLE", "purpose": "login"}), 429)
	})
}

func TestRefreshRotationReuseAndRevocation(t *testing.T) {
	h := newHarness(t, nil)
	first := h.login(t, "GOOGLE", "sessions-subject")
	second := h.login(t, "GOOGLE", "sessions-subject")
	bad := strings.Split(first.Tokens.RefreshToken, ".")[0] + "." + strings.Repeat("A", 43)
	expect(t, h.request("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": bad}), 401)
	expect(t, h.request("GET", "/v1/me", first.Tokens.AccessToken, nil), 200)
	rotated := decode[identity.LoginResult](t, expect(t, h.request("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": first.Tokens.RefreshToken}), 200))
	expect(t, h.request("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": first.Tokens.RefreshToken}), 401)
	expect(t, h.request("GET", "/v1/me", rotated.Tokens.AccessToken, nil), 401)
	expect(t, h.request("GET", "/v1/me", second.Tokens.AccessToken, nil), 200)
	third := h.login(t, "GOOGLE", "sessions-subject")
	expect(t, h.request("DELETE", "/v1/me/sessions/"+third.Tokens.SessionID, second.Tokens.AccessToken, nil), 204)
	expect(t, h.request("GET", "/v1/me", third.Tokens.AccessToken, nil), 401)
	expect(t, h.request("POST", "/v1/me/sessions/revoke-all", second.Tokens.AccessToken, nil), 204)
	expect(t, h.request("GET", "/v1/me", second.Tokens.AccessToken, nil), 401)
	fourth := h.login(t, "GOOGLE", "sessions-subject")
	expect(t, h.request("POST", "/v1/auth/logout", fourth.Tokens.AccessToken, nil), 204)
	expect(t, h.request("GET", "/v1/me", fourth.Tokens.AccessToken, nil), 401)
}

func TestConcurrentRefreshAndExpiration(t *testing.T) {
	h := newHarness(t, nil)
	login := h.login(t, "GOOGLE", "concurrent-refresh")
	results := make(chan result, 2)
	for range 2 {
		go func() {
			results <- h.request("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": login.Tokens.RefreshToken})
		}()
	}
	success, denied := 0, 0
	var issued identity.LoginResult
	for range 2 {
		r := <-results
		if r.status == 200 {
			success++
			issued = decode[identity.LoginResult](t, expect(t, r, 200))
		} else {
			denied++
			expect(t, r, 401)
		}
	}
	if success != 1 || denied != 1 {
		t.Fatal("refresh race did not enforce single use")
	}
	expect(t, h.request("GET", "/v1/me", issued.Tokens.AccessToken, nil), 401)
	second := h.login(t, "GOOGLE", "concurrent-refresh")
	execSQL(t, "UPDATE identity.access_credentials SET expires_at=now()-interval '1 second' WHERE session_id=$1", second.Tokens.SessionID)
	expect(t, h.request("GET", "/v1/me", second.Tokens.AccessToken, nil), 401)
	execSQL(t, "UPDATE identity.sessions SET created_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE id=$1", second.Tokens.SessionID)
	expect(t, h.request("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": second.Tokens.RefreshToken}), 401)
}

func TestRetentionPreservesRefreshReplayWindow(t *testing.T) {
	h := newHarness(t, nil)
	old := h.login(t, "GOOGLE", "retention")
	recent := h.login(t, "GOOGLE", "retention")
	execSQL(t, "UPDATE identity.sessions SET created_at=now()-interval '70 days',expires_at=now()-interval '31 days' WHERE id=$1", old.Tokens.SessionID)
	execSQL(t, "UPDATE identity.sessions SET created_at=now()-interval '40 days',expires_at=now()-interval '1 day' WHERE id=$1", recent.Tokens.SessionID)
	command := exec.Command("go", "run", "./cmd/identity-retention")
	command.Dir = "../../.."
	command.Env = append(os.Environ(), "DATABASE_URL="+os.Getenv("FLOW_IDENTITY_TEST_DATABASE_URL"))
	if b, e := command.CombinedOutput(); e != nil {
		t.Fatalf("retention command failed: %s", b)
	}
	if count(t, "SELECT count(*) FROM identity.refresh_credentials WHERE session_id=$1", old.Tokens.SessionID) != 0 {
		t.Fatal("history past retention not removed")
	}
	if count(t, "SELECT count(*) FROM identity.refresh_credentials WHERE session_id=$1", recent.Tokens.SessionID) != 1 {
		t.Fatal("refresh replay history removed too early")
	}
	if count(t, "SELECT count(*) FROM identity.users") != 1 {
		t.Fatal("retention deleted user")
	}
}

func TestIdentityLinkingReauthAndRestrictions(t *testing.T) {
	h := newHarness(t, nil)
	a := h.login(t, "GOOGLE", "account-a")
	b := h.login(t, "APPLE", "account-b")
	c := h.challenge(t, "APPLE", "link", a.Tokens.AccessToken, "")
	proof := identity.Proof{Provider: "APPLE", ChallengeID: c.ID, Credential: token(t, "APPLE", "account-b", c.Nonce)}
	expect(t, h.request("POST", "/v1/me/identities/link", a.Tokens.AccessToken, proof), 409)
	c = h.challenge(t, "APPLE", "link", a.Tokens.AccessToken, "")
	proof = identity.Proof{Provider: "APPLE", ChallengeID: c.ID, Credential: token(t, "APPLE", "new-linked-identity", c.Nonce)}
	expect(t, h.request("POST", "/v1/me/identities/link", a.Tokens.AccessToken, proof), 204)
	expect(t, h.request("POST", "/v1/me/identities/link", a.Tokens.AccessToken, proof), 204)
	list := decode[struct {
		Items []identity.LinkedIdentity `json:"items"`
	}](t, expect(t, h.request("GET", "/v1/me/identities", a.Tokens.AccessToken, nil), 200))
	if len(list.Items) != 2 {
		t.Fatal("link not committed")
	}
	execSQL(t, "UPDATE identity.sessions SET reauthenticated_at=now()-interval '10 minutes' WHERE id=$1", a.Tokens.SessionID)
	expect(t, h.request("POST", "/v1/auth/oidc/challenges", a.Tokens.AccessToken, map[string]string{"provider": "APPLE", "purpose": "link"}), 403)
	c = h.challenge(t, "GOOGLE", "reauth", a.Tokens.AccessToken, "")
	proof = identity.Proof{Provider: "GOOGLE", ChallengeID: c.ID, Credential: token(t, "GOOGLE", "account-a", c.Nonce)}
	expect(t, h.request("POST", "/v1/auth/reauthenticate", a.Tokens.AccessToken, proof), 204)
	results := make(chan result, 2)
	for _, item := range list.Items {
		go func() { results <- h.request("DELETE", "/v1/me/identities/"+item.ID, a.Tokens.AccessToken, nil) }()
	}
	ok, denied := 0, 0
	for range 2 {
		r := <-results
		if r.status == 204 {
			ok++
			expect(t, r, 204)
		} else {
			denied++
			expect(t, r, 409)
		}
	}
	if ok != 1 || denied != 1 {
		t.Fatal("last identity protection not concurrent-safe")
	}
	for _, status := range []string{"suspended", "disabled", "deleted"} {
		execSQL(t, "UPDATE identity.users SET status=$2 WHERE id=$1", b.User.ID, status)
		expect(t, h.request("GET", "/v1/me", b.Tokens.AccessToken, nil), 403)
		expect(t, h.request("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": b.Tokens.RefreshToken}), 403)
	}
	// Uma prova válida do mesmo provedor também não cria outra conta para contornar status.
	c = h.challenge(t, "APPLE", "login", "", "")
	expect(t, h.request("POST", "/v1/auth/apple", "", map[string]any{"challenge_id": c.ID, "id_token": token(t, "APPLE", "account-b", c.Nonce), "device": identity.Device{Platform: "ios", AppVersion: "0.1.0"}}), 403)
	if count(t, "SELECT count(*) FROM identity.users") != 2 {
		t.Fatal("restriction bypass created account")
	}
}

func TestNonceBindingAppleRevocationAndSecretRedaction(t *testing.T) {
	h := newHarness(t, nil)
	c := h.challenge(t, "APPLE", "login", "", "")
	raw := token(t, "APPLE", "nonce-subject", "incorrect-nonce")
	expect(t, h.request("POST", "/v1/auth/apple", "", map[string]any{"challenge_id": c.ID, "id_token": raw, "device": identity.Device{Platform: "ios", AppVersion: "0.1.0"}}), 401)
	login := h.login(t, "APPLE", "revoked-apple")
	payload := signed(t, jwt.MapClaims{"iss": "https://appleid.apple.com", "aud": "com.example.flow.test", "iat": time.Now().Unix(), "jti": "unique-event", "events": map[string]any{"type": "consent-revoked", "sub": "revoked-apple", "event_time": time.Now().Unix()}})
	expect(t, h.request("POST", "/v1/auth/apple/notifications", "", map[string]string{"payload": payload}), 204)
	n := count(t, "SELECT count(*) FROM integration.outbox")
	expect(t, h.request("POST", "/v1/auth/apple/notifications", "", map[string]string{"payload": payload}), 204)
	if count(t, "SELECT count(*) FROM integration.outbox") != n {
		t.Fatal("notification replay not idempotent")
	}
	expect(t, h.request("GET", "/v1/me", login.Tokens.AccessToken, nil), 401)
	var audit string
	e := pool.QueryRow(context.Background(), "SELECT COALESCE(jsonb_agg(to_jsonb(a))::text,'') FROM identity.audit_events a").Scan(&audit)
	if e != nil {
		t.Fatal(e)
	}
	for _, secret := range []string{raw, payload, login.Tokens.RefreshToken, login.Tokens.AccessToken, "sensitive-provider-debug", "same@privaterelay.appleid.com"} {
		if strings.Contains(audit, secret) || strings.Contains(h.logs.String(), secret) {
			t.Fatal("sensitive audit/log input exposed")
		}
	}
	if count(t, "SELECT count(*) FROM identity.audit_events WHERE outcome='denied'") == 0 {
		t.Fatal("security denial audit missing")
	}
}

func TestHTTPTrustBoundariesAndSMSBuckets(t *testing.T) {
	t.Run("strict bodies and no password flow", func(t *testing.T) {
		h := newHarness(t, nil)
		expect(t, h.request("GET", "/v1/me", "", nil), 401)
		expect(t, h.request("POST", "/v1/auth/password", "", map[string]string{"username": "test", "password": "not-supported"}), 404)
		expect(t, h.request("POST", "/v1/auth/phone/challenges", "", map[string]string{"phone": "+5511999999999", "purpose": "login", "provider_subject": "client-assertion"}), 400)
		expect(t, h.request("POST", "/v1/auth/phone/challenges", "", map[string]string{"phone": strings.Repeat("x", 34000), "purpose": "login"}), 413)
	})
	for _, name := range []string{"number", "sms origin", "global minute"} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t, func(c *identity.Config) {
				switch name {
				case "number":
					c.SMSNumberHour = 1
				case "sms origin":
					c.SMSOriginHour = 1
				case "global minute":
					c.SMSGlobalMinute = 1
				}
			})
			c := h.challenge(t, "PHONE", "login", "", "+5511999999999")
			phone := "+5511988888888"
			if name == "number" {
				phone = "+5511999999999"
				execSQL(t, "UPDATE identity.challenges SET created_at=now()-interval '61 seconds' WHERE id=$1", c.ID)
			}
			expect(t, h.request("POST", "/v1/auth/phone/challenges", "", map[string]string{"phone": phone, "purpose": "login"}), 429)
			if smsCounter.Load() != 1 {
				t.Fatal("quota allowed extra paid verification")
			}
		})
	}

	t.Run("untrusted forwarded header", func(t *testing.T) {
		h := newHarness(t, func(c *identity.Config) { c.OriginMinute = 1 })
		h.challenge(t, "GOOGLE", "login", "", "")
		req, _ := http.NewRequest("POST", h.server.URL+"/v1/auth/oidc/challenges", strings.NewReader(`{"provider":"GOOGLE","purpose":"login"}`))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Forwarded-For", "203.0.113.99")
		res, e := h.server.Client().Do(req)
		if e != nil {
			t.Fatal(e)
		}
		defer res.Body.Close()
		if res.StatusCode != 429 {
			t.Fatal("spoofed source bypassed limit")
		}
	})
}
