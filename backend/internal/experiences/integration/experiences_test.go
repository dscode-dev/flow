//go:build integration

package integration

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"flow.local/backend/internal/experiences"
	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/httpapi"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/legacy"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

var pool *pgxpool.Pool
var contract routers.Router
var store *s3.Client

const bucket = "flow-experiences-test"

func TestMain(m *testing.M) {
	dsn := os.Getenv("FLOW_EXPERIENCES_TEST_DATABASE_URL")
	u, e := url.Parse(dsn)
	if e != nil || u.Path != "/flow_experiences_test" {
		fmt.Fprintln(os.Stderr, "Use make experiences-test; exige flow_experiences_test isolado.")
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
	// Rollback only the new schema while an Identity record survives.
	marker := uuid.NewString()
	if _, e = db.Exec("INSERT INTO identity.users(id) VALUES($1)", marker); e != nil {
		panic(e)
	}
	if e = goose.Down(db, "../../../migrations"); e != nil {
		panic(e)
	}
	var ok bool
	if e = db.QueryRow("SELECT to_regnamespace('experiences') IS NULL AND to_regnamespace('media') IS NULL AND EXISTS(SELECT FROM identity.users WHERE id=$1) AND EXISTS(SELECT FROM pg_extension WHERE extname='postgis') AND to_regclass('integration.outbox') IS NOT NULL", marker).Scan(&ok); e != nil || !ok {
		panic("migration boundary failed")
	}
	if e = goose.Up(db, "../../../migrations"); e != nil {
		panic(e)
	}
	if _, e = db.Exec("DELETE FROM identity.users WHERE id=$1", marker); e != nil {
		panic(e)
	}
	_ = db.Close()
	pool, e = pgxpool.New(context.Background(), dsn)
	if e != nil {
		panic(e)
	}
	doc, e := openapi3.NewLoader().LoadFromFile("../../../../contracts/openapi/flow.yaml")
	if e != nil {
		panic(e)
	}
	if e = doc.Validate(context.Background()); e != nil {
		panic(e)
	}
	contract, e = legacy.NewRouter(doc)
	if e != nil {
		panic(e)
	}
	sc, e := media.ParseStorageConfig(os.Getenv)
	if e != nil || sc.Endpoint == "" {
		panic("real S3 configuration required")
	}
	store = s3.NewFromConfig(aws.Config{Region: sc.Region, Credentials: credentials.NewStaticCredentialsProvider(sc.AccessKey, sc.SecretKey, sc.SessionToken), HTTPClient: &http.Client{Timeout: 8 * time.Second}, RetryMaxAttempts: 1}, func(o *s3.Options) {
		o.BaseEndpoint = &sc.Endpoint
		o.UsePathStyle = true
		o.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	_, e = store.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(bucket)})
	if e != nil {
		_, e = store.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(bucket)})
	}
	cancel()
	if e != nil {
		panic("real test S3 bucket unavailable")
	}
	if !cleanTestBucket() {
		panic("test bucket cleanup failed")
	}
	code := m.Run()
	if !cleanTestBucket() {
		fmt.Fprintln(os.Stderr, "test bucket cleanup failed")
		code = 1
	}
	pool.Close()
	os.Exit(code)
}

// Never touch the application's bucket. Fixtures use a fixed, isolated bucket
// and are removed even though schema rollback intentionally drops their rows.
func cleanTestBucket() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for range 100 {
		page, err := store.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: aws.String(bucket), MaxKeys: aws.Int32(100)})
		if err != nil {
			return false
		}
		if len(page.Contents) == 0 {
			return true
		}
		for _, item := range page.Contents {
			if _, err = store.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: item.Key}); err != nil {
				return false
			}
		}
	}
	return false
}

type checker struct{}

func (checker) Check(context.Context) map[string]bool { return map[string]bool{"postgres": true} }

type harness struct {
	server  *httptest.Server
	service *experiences.Service
	media   *media.Service
}

func newHarness(t *testing.T, limits ...int) *harness {
	t.Helper()
	key := bytes.Repeat([]byte{71}, 32)
	c, e := experiences.ParseConfig(func(string) string { return "" }, key)
	if e != nil {
		t.Fatal(e)
	}
	// Higher explicit quotas avoid unrelated tests exhausting the same config.
	c.CreateDaily = 100
	c.PublishDaily = 100
	c.MaxDrafts = 100
	c.UploadDaily = 100
	if len(limits) == 4 {
		c.CreateDaily = limits[0]
		c.PublishDaily = limits[1]
		c.MaxDrafts = limits[2]
		c.UploadDaily = limits[3]
	}
	sc, e := media.ParseStorageConfig(os.Getenv)
	if e != nil {
		t.Fatal(e)
	}
	sc.Bucket = bucket
	ms := media.New(pool, media.NewStorage(sc), c.UploadDaily)
	es := experiences.New(pool, ms, c)
	auth := identityhttp.New(identity.NewService(context.Background(), pool, identity.Config{HMACKey: key, OriginMinute: 1000}))
	handler := experiences.NewHandler(es, ms, auth)
	server := httptest.NewServer(httpapi.New(slog.New(slog.NewTextHandler(io.Discard, nil)), checker{}, 1<<20, time.Second, func() bool { return false }, auth.Register, handler.Register))
	t.Cleanup(server.Close)
	return &harness{server, es, ms}
}

type actor struct{ user, session, token string }

func user(t *testing.T, onboard bool) actor {
	t.Helper()
	a := actor{user: uuid.NewString(), session: uuid.NewString()}
	device := uuid.NewString()
	secret := make([]byte, 32)
	if _, e := rand.Read(secret); e != nil {
		t.Fatal(e)
	}
	a.token = "fa_" + base64.RawURLEncoding.EncodeToString(secret)
	hash := sha256.Sum256([]byte(a.token))
	ctx := context.Background()
	tx, e := pool.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(ctx)
	if _, e = tx.Exec(ctx, "INSERT INTO identity.users(id,onboarding_completed_at) VALUES($1,CASE WHEN $2::boolean THEN now() ELSE NULL END)", a.user, onboard); e != nil {
		t.Fatal(e)
	}
	if _, e = tx.Exec(ctx, "INSERT INTO identity.profiles(user_id) VALUES($1)", a.user); e != nil {
		t.Fatal(e)
	}
	if _, e = tx.Exec(ctx, "INSERT INTO identity.devices(id,user_id,platform,app_version) VALUES($1,$2,'android','integration')", device, a.user); e != nil {
		t.Fatal(e)
	}
	if _, e = tx.Exec(ctx, "INSERT INTO identity.sessions(id,user_id,device_id,authenticated_provider,expires_at) VALUES($1,$2,$3,'GOOGLE',now()+interval '1 hour')", a.session, a.user, device); e != nil {
		t.Fatal(e)
	}
	if _, e = tx.Exec(ctx, "INSERT INTO identity.access_credentials(credential_hash,session_id,expires_at) VALUES($1,$2,now()+interval '10 minutes')", hash[:], a.session); e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(ctx); e != nil {
		t.Fatal(e)
	}
	return a
}

type result struct {
	status int
	header http.Header
	raw    []byte
}

func (h *harness) call(t *testing.T, method, path string, a actor, body any, headers map[string]string, want int) result {
	t.Helper()
	var raw []byte
	if body != nil {
		var e error
		raw, e = json.Marshal(body)
		if e != nil {
			t.Fatal(e)
		}
	}
	return h.request(t, method, path, a, raw, headers, want)
}
func (h *harness) request(t *testing.T, method, path string, a actor, body []byte, headers map[string]string, want int) result {
	t.Helper()
	req, e := http.NewRequest(method, h.server.URL+path, bytes.NewReader(body))
	if e != nil {
		t.Fatal(e)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if a.token != "" {
		req.Header.Set("Authorization", "Bearer "+a.token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, e := h.server.Client().Do(req)
	if e != nil {
		t.Fatal(e)
	}
	defer res.Body.Close()
	raw, e := io.ReadAll(res.Body)
	if e != nil {
		t.Fatal(e)
	}
	if res.StatusCode != want {
		var envelope httpapi.Envelope
		_ = json.Unmarshal(raw, &envelope)
		t.Fatalf("%s %s: got %d want %d code=%s", method, strings.Split(path, "?")[0], res.StatusCode, want, envelope.Error.Code)
	}
	// OpenAPI uses a relative server URL, as in the existing Identity harness.
	req.URL.Scheme, req.URL.Host = "", ""
	route, params, e := contract.FindRoute(req)
	if e != nil {
		t.Fatal(e)
	}
	input := &openapi3filter.RequestValidationInput{Request: req, PathParams: params, Route: route, Options: &openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc}}
	if want < 400 {
		req.Body = io.NopCloser(bytes.NewReader(body))
		if e = openapi3filter.ValidateRequest(context.Background(), input); e != nil {
			t.Fatalf("request contract %s: %v", route.Operation.OperationID, e)
		}
	}
	output := &openapi3filter.ResponseValidationInput{RequestValidationInput: input, Status: res.StatusCode, Header: res.Header, Body: io.NopCloser(bytes.NewReader(raw)), Options: &openapi3filter.Options{IncludeResponseStatus: true}}
	if e = openapi3filter.ValidateResponse(context.Background(), output); e != nil {
		t.Fatalf("response contract %s: %v", route.Operation.OperationID, e)
	}
	if res.Header.Get("Cache-Control") != "no-store" {
		t.Fatal("cache policy")
	}
	return result{res.StatusCode, res.Header, raw}
}
func experience(t *testing.T, r result) experiences.Experience {
	t.Helper()
	var e experiences.Experience
	if err := json.Unmarshal(r.raw, &e); err != nil {
		t.Fatal(err)
	}
	return e
}
func code(t *testing.T, r result, want string) {
	t.Helper()
	var e httpapi.Envelope
	if json.Unmarshal(r.raw, &e) != nil || e.Error.Code != want {
		t.Fatalf("want error %s", want)
	}
}
func match(e experiences.Experience) map[string]string {
	return map[string]string{"If-Match": fmt.Sprintf("\"%d\"", e.Version)}
}
func create(t *testing.T, h *harness, a actor, in experiences.Input) experiences.Experience {
	return experience(t, h.call(t, "POST", "/v1/experiences", a, in, map[string]string{"Idempotency-Key": uuid.NewString()}, 201))
}
func fullInput(visibility string) experiences.Input {
	now := time.Now().UTC().Truncate(time.Second)
	start, end := now.Add(time.Hour), now.Add(3*time.Hour)
	category, tz, ticket := "music", "America/Recife", "https://tickets.example/events/flow"
	return experiences.Input{Title: "Encontro de música", Description: "Experiência presencial para ouvir música e conversar.", CategoryID: &category, Visibility: visibility, StartsAt: &start, EndsAt: &end, Timezone: &tz, Location: &experiences.Location{Latitude: -8.0476, Longitude: -34.877}, VenueName: "Praça pública", Address: "Endereço público autorizado", ExternalTicketURL: &ticket}
}
func publish(t *testing.T, h *harness, a actor, e experiences.Experience) experiences.Experience {
	return experience(t, h.call(t, "POST", "/v1/experiences/"+e.ID+"/publish", a, struct{}{}, match(e), 200))
}

func TestLifecycleVisibilityAndContracts(t *testing.T) {
	h := newHarness(t)
	a, b := user(t, true), user(t, true)
	h.call(t, "GET", "/v1/experience-categories", actor{}, nil, nil, 401)
	cats := h.call(t, "GET", "/v1/experience-categories", a, nil, nil, 200)
	if !bytes.Contains(cats.raw, []byte(`"music"`)) {
		t.Fatal("seed catalog")
	}
	h.call(t, "GET", "/v1/me", a, nil, nil, 200) // Existing Identity composition survives.
	draft := create(t, h, a, experiences.Input{})
	if draft.Status != "DRAFT" || draft.Title != "" || draft.Version != 1 || draft.Visibility != "PRIVATE" {
		t.Fatal("partial draft")
	}
	code(t, h.call(t, "GET", "/v1/experiences/"+draft.ID, b, nil, nil, 404), "not_found")
	code(t, h.call(t, "POST", "/v1/experiences/"+draft.ID+"/publish", a, struct{}{}, match(draft), 422), "experience_invalid")
	h.call(t, "PUT", "/v1/experiences/"+draft.ID, a, fullInput("PUBLIC"), nil, 428)
	in := fullInput("PUBLIC")
	draft = experience(t, h.call(t, "PUT", "/v1/experiences/"+draft.ID, a, in, match(draft), 200))
	published := publish(t, h, a, draft)
	if published.PublishedAt == nil || published.Phase == nil || *published.Phase != "UPCOMING" {
		t.Fatal("publication")
	}
	other := experience(t, h.call(t, "GET", "/v1/experiences/"+published.ID, b, nil, nil, 200))
	if other.Location == nil || other.DetailsRedacted {
		t.Fatal("published details")
	}
	in.Visibility = "PRIVATE"
	code(t, h.call(t, "PUT", "/v1/experiences/"+published.ID, a, in, match(published), 409), "protected_attributes")
	code(t, h.call(t, "PUT", "/v1/experiences/"+published.ID, b, published.Input, match(published), 404), "not_found")
	in = published.Input
	in.Title = "Título corrigido"
	published = experience(t, h.call(t, "PUT", "/v1/experiences/"+published.ID, a, in, match(published), 200))
	h.call(t, "POST", "/v1/experiences/"+published.ID+"/archive", a, struct{}{}, match(published), 409)
	cancelled := experience(t, h.call(t, "POST", "/v1/experiences/"+published.ID+"/cancel", a, struct{}{}, match(published), 200))
	if cancelled.CancelledAt == nil || cancelled.Phase != nil {
		t.Fatal("cancelled")
	}
	history := experience(t, h.call(t, "GET", "/v1/experiences/"+published.ID, b, nil, nil, 200))
	if !history.DetailsRedacted || history.Location != nil || history.ExternalTicketURL != nil || history.Description != "" {
		t.Fatal("historical redaction")
	}
	code(t, h.call(t, "POST", "/v1/experiences/"+published.ID+"/publish", a, struct{}{}, match(cancelled), 409), "invalid_transition")
	archived := experience(t, h.call(t, "POST", "/v1/experiences/"+published.ID+"/archive", a, struct{}{}, match(cancelled), 200))
	if archived.Status != "ARCHIVED" || archived.ArchivedAt == nil {
		t.Fatal("archive")
	}
	for _, visibility := range []string{"PRIVATE", "UNLISTED", "PUBLIC"} {
		e := publish(t, h, a, create(t, h, a, fullInput(visibility)))
		want := 200
		if visibility == "PRIVATE" {
			want = 404
		}
		h.call(t, "GET", "/v1/experiences/"+e.ID, b, nil, nil, want)
		page := h.call(t, "GET", "/v1/experiences", b, nil, nil, 200)
		if bytes.Contains(page.raw, []byte(e.ID)) != (visibility == "PUBLIC") {
			t.Fatalf("discovery leaked %s", visibility)
		}
	}
	list := h.call(t, "GET", "/v1/me/experiences?status=ARCHIVED", a, nil, nil, 200)
	if !bytes.Contains(list.raw, []byte(archived.ID)) {
		t.Fatal("creator historical list")
	}
	public := h.call(t, "GET", "/v1/experiences", b, nil, nil, 200)
	if bytes.Contains(public.raw, []byte(archived.ID)) {
		t.Fatal("cancel/archive rediscovered")
	}
	// State-transition no-op with current ETag creates no extra fact/version.
	h.call(t, "POST", "/v1/experiences/"+archived.ID+"/archive", a, struct{}{}, match(archived), 200)
	assertEvents(t, archived.ID, []string{"experience.created", "experience.updated", "experience.published", "experience.updated", "experience.cancelled", "experience.archived"})
}

func assertEvents(t *testing.T, eid string, want []string) {
	t.Helper()
	f, err := os.Open("../../../../contracts/events/experience-payload.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	doc, err := jsonschema.UnmarshalJSON(f)
	if err != nil {
		t.Fatal(err)
	}
	c := jsonschema.NewCompiler()
	c.DefaultDraft(jsonschema.Draft2020)
	c.AssertFormat()
	const schemaURL = "urn:flow:tests:experience-payload"
	if err = c.AddResource(schemaURL, doc); err != nil {
		t.Fatal(err)
	}
	schema, err := c.Compile(schemaURL)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(context.Background(), "SELECT event_type,payload FROM integration.outbox WHERE aggregate_id=$1 ORDER BY (payload->>'version')::bigint", eid)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	i := 0
	for rows.Next() {
		var kind string
		var raw []byte
		if err = rows.Scan(&kind, &raw); err != nil {
			t.Fatal(err)
		}
		if i >= len(want) || kind != want[i] {
			t.Fatal("lifecycle event sequence", i, kind)
		}
		value, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
		if err != nil {
			t.Fatal(err)
		}
		if err = schema.Validate(value); err != nil {
			t.Fatal("outbox payload contract", err)
		}
		i++
	}
	if rows.Err() != nil || i != len(want) {
		t.Fatal("outbox event count", i)
	}
}
func TestConcurrencyIdempotencyAndAtomicOutbox(t *testing.T) {
	h := newHarness(t)
	a := user(t, true)
	key := uuid.NewString()
	in := experiences.Input{Title: "Rascunho"}
	headers := map[string]string{"Idempotency-Key": key}
	var wg sync.WaitGroup
	results := make(chan experiences.Experience, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := h.call(t, "POST", "/v1/experiences", a, in, headers, 201)
			results <- experience(t, r)
		}()
	}
	wg.Wait()
	close(results)
	var created experiences.Experience
	for r := range results {
		if created.ID != "" && created.ID != r.ID {
			t.Fatal("duplicate create")
		}
		created = r
	}
	var count int
	if e := pool.QueryRow(context.Background(), "SELECT count(*) FROM integration.outbox WHERE aggregate_id=$1", created.ID).Scan(&count); e != nil || count != 1 {
		t.Fatal("idempotent outbox", e, count)
	}
	in.Title = "Other"
	code(t, h.call(t, "POST", "/v1/experiences", a, in, headers, 409), "idempotency_conflict")
	statuses := make(chan int, 2)
	// Service boundary returns typed version failure; both real transactions race.
	for i := range 2 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			v := created.Input
			v.Title = fmt.Sprintf("Concurrent %d", i)
			_, e := h.service.Update(context.Background(), &identity.Session{ID: a.session, UserID: a.user}, created.ID, created.Version, v, "concurrency")
			if e == nil {
				statuses <- 200
			} else if e == experiences.ErrVersion {
				statuses <- 412
			} else {
				t.Errorf("concurrent update: %v", e)
			}
		}(i)
	}
	wg.Wait()
	close(statuses)
	seen := map[int]int{}
	for s := range statuses {
		seen[s]++
	}
	if seen[200] != 1 || seen[412] != 1 {
		t.Fatal("lost update", seen)
	}
	current := experience(t, h.call(t, "GET", "/v1/experiences/"+created.ID, a, nil, nil, 200))
	if current.Version != 2 {
		t.Fatal("version")
	}
	replay := experience(t, h.call(t, "POST", "/v1/experiences", a, experiences.Input{Title: "Rascunho"}, headers, 201))
	if replay.Version != 1 || replay.Title != "Rascunho" {
		t.Fatal("original response snapshot")
	}
	h.call(t, "PUT", "/v1/experiences/"+created.ID, a, current.Input, match(created), 412)
	if e := pool.QueryRow(context.Background(), `SELECT count(*) FROM integration.outbox o JOIN experiences.audit_events a ON a.experience_id=o.aggregate_id AND a.version=(o.payload->>'version')::bigint AND a.action=o.event_type WHERE o.aggregate_id=$1`, created.ID).Scan(&count); e != nil || count != 2 {
		t.Fatal("atomic event/audit/version", e, count)
	}
	// Force the outbox append to fail after aggregate/audit writes, then verify
	// transaction rollback leaves neither an orphan aggregate nor an audit row.
	exec(t, `ALTER TABLE integration.outbox ADD CONSTRAINT experiences_test_reject CHECK(event_type<>'experience.created') NOT VALID`)
	defer exec(t, `ALTER TABLE integration.outbox DROP CONSTRAINT IF EXISTS experiences_test_reject`)
	key = uuid.NewString()
	h.call(t, "POST", "/v1/experiences", a, experiences.Input{Title: "must roll back"}, map[string]string{"Idempotency-Key": key}, 503)
	if e := pool.QueryRow(context.Background(), "SELECT count(*) FROM experiences.experiences WHERE creator_user_id=$1", a.user).Scan(&count); e != nil || count != 1 {
		t.Fatal("aggregate rollback", e, count)
	}
	if e := pool.QueryRow(context.Background(), "SELECT count(*) FROM experiences.audit_events WHERE actor_user_id=$1", a.user).Scan(&count); e != nil || count != 2 {
		t.Fatal("audit rollback", e, count)
	}
}
func exec(t *testing.T, q string, args ...any) {
	t.Helper()
	if _, e := pool.Exec(context.Background(), q, args...); e != nil {
		t.Fatal(e)
	}
}

func TestEligibilityQuotasModerationAndValidation(t *testing.T) {
	h := newHarness(t, 2, 1, 10, 1)
	a, b := user(t, true), user(t, false)
	code(t, h.call(t, "POST", "/v1/experiences", b, experiences.Input{}, map[string]string{"Idempotency-Key": uuid.NewString()}, 403), "onboarding_required")
	h.request(t, "POST", "/v1/experiences", a, []byte(`{"creator_user_id":"forged"}`), map[string]string{"Idempotency-Key": uuid.NewString()}, 400)
	h.request(t, "POST", "/v1/experiences", a, []byte(`null`), map[string]string{"Idempotency-Key": uuid.NewString()}, 400)
	for _, body := range []string{`{"visibility":""}`, `{"title":null}`, `{"location":{"longitude":1}}`, `{"location":{"latitude":null,"longitude":1}}`} {
		h.request(t, "POST", "/v1/experiences", a, []byte(body), map[string]string{"Idempotency-Key": uuid.NewString()}, 400)
	}
	h.request(t, "POST", "/v1/experiences", a, []byte(`{"description":"`+strings.Repeat("a", 33000)+`"}`), map[string]string{"Idempotency-Key": uuid.NewString()}, 413)
	bad := fullInput("PUBLIC")
	bad.ExternalTicketURL = ptr("javascript:alert(1)")
	h.call(t, "POST", "/v1/experiences", a, bad, map[string]string{"Idempotency-Key": uuid.NewString()}, 422)
	first := create(t, h, a, fullInput("PUBLIC"))
	second := create(t, h, a, fullInput("PRIVATE"))
	code(t, h.call(t, "POST", "/v1/experiences", a, experiences.Input{}, map[string]string{"Idempotency-Key": uuid.NewString()}, 429), "rate_limited")
	exec(t, "INSERT INTO experiences.publishing_restrictions(creator_user_id,blocked_until,reason_code) VALUES($1,now()+interval '1 day','fixture')", a.user)
	code(t, h.call(t, "POST", "/v1/experiences/"+first.ID+"/publish", a, struct{}{}, match(first), 403), "publishing_restricted")
	exec(t, "DELETE FROM experiences.publishing_restrictions WHERE creator_user_id=$1", a.user)
	published := publish(t, h, a, first)
	h.call(t, "POST", "/v1/experiences/"+second.ID+"/publish", a, struct{}{}, match(second), 429)
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD' WHERE id=$1", published.ID)
	h.call(t, "GET", "/v1/experiences/"+published.ID, b, nil, nil, 404)
	if bytes.Contains(h.call(t, "GET", "/v1/experiences", b, nil, nil, 200).raw, []byte(published.ID)) {
		t.Fatal("withheld discovered")
	}
	exec(t, "UPDATE identity.users SET status='suspended' WHERE id=$1", a.user)
	code(t, h.call(t, "GET", "/v1/me/experiences", a, nil, nil, 403), "account_restricted")
	code(t, h.call(t, "POST", "/v1/experiences", a, experiences.Input{}, map[string]string{"Idempotency-Key": uuid.NewString()}, 403), "account_restricted")
	for _, status := range []string{"disabled", "deleted"} {
		exec(t, "UPDATE identity.users SET status=$2 WHERE id=$1", a.user, status)
		h.call(t, "GET", "/v1/experiences/"+first.ID, a, nil, nil, 403)
	}
	exec(t, "UPDATE identity.users SET status='active' WHERE id=$1", a.user)
	exec(t, "UPDATE identity.sessions SET revoked_at=now(),revocation_reason='fixture' WHERE id=$1", a.session)
	h.call(t, "GET", "/v1/me/experiences", a, nil, nil, 401)
}
func ptr(v string) *string { return &v }

func TestSpatialTemporalAndCursorBoundaries(t *testing.T) {
	h := newHarness(t)
	a := user(t, true)
	in := fullInput("PUBLIC")
	liveStart := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	liveEnd := liveStart.Add(2 * time.Hour)
	in.StartsAt = &liveStart
	in.EndsAt = &liveEnd
	in.Timezone = ptr("America/New_York")
	live := publish(t, h, a, create(t, h, a, in))
	if live.Phase == nil || *live.Phase != "LIVE" {
		t.Fatal("live publication")
	}
	far := fullInput("PUBLIC")
	far.Location = &experiences.Location{Latitude: 35.6762, Longitude: 139.6503}
	distant := publish(t, h, a, create(t, h, a, far))
	near := h.call(t, "GET", "/v1/experiences?latitude=-8.0476&longitude=-34.877&radius_m=1000", a, nil, nil, 200)
	if !bytes.Contains(near.raw, []byte(live.ID)) || bytes.Contains(near.raw, []byte(distant.ID)) {
		t.Fatal("PostGIS distance")
	}
	h.call(t, "GET", "/v1/experiences?latitude=NaN&longitude=0&radius_m=1000", a, nil, nil, 400)
	h.call(t, "GET", "/v1/experiences?latitude=0", a, nil, nil, 400)
	h.call(t, "GET", "/v1/experiences?limit=1&limit=2", a, nil, nil, 400)
	var page experiences.Page
	r := h.call(t, "GET", "/v1/me/experiences?limit=1", a, nil, nil, 200)
	if json.Unmarshal(r.raw, &page) != nil || page.NextCursor == nil {
		t.Fatal("cursor")
	}
	next := url.QueryEscape(*page.NextCursor)
	r = h.call(t, "GET", "/v1/me/experiences?limit=1&cursor="+next, a, nil, nil, 200)
	var second experiences.Page
	_ = json.Unmarshal(r.raw, &second)
	if len(second.Items) != 1 || second.Items[0].ID == page.Items[0].ID {
		t.Fatal("keyset pagination")
	}
	h.call(t, "GET", "/v1/me/experiences?limit=2&cursor="+next, a, nil, nil, 400)
	h.call(t, "GET", "/v1/me/experiences?limit=1&cursor="+url.QueryEscape(*page.NextCursor+"x"), a, nil, nil, 400)
	b := user(t, true)
	h.call(t, "GET", "/v1/me/experiences?limit=1&cursor="+next, b, nil, nil, 400)
	exec(t, "UPDATE experiences.experiences SET starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour' WHERE id=$1", live.ID)
	ended := experience(t, h.call(t, "GET", "/v1/experiences/"+live.ID, a, nil, nil, 200))
	if ended.Phase == nil || *ended.Phase != "ENDED" {
		t.Fatal("derived ended")
	}
	h.call(t, "POST", "/v1/experiences/"+ended.ID+"/cancel", a, struct{}{}, match(ended), 409)
	archived := experience(t, h.call(t, "POST", "/v1/experiences/"+ended.ID+"/archive", a, struct{}{}, match(ended), 200))
	if archived.Status != "ARCHIVED" {
		t.Fatal("finish")
	}
	// Actual UTC instants spanning the fall-back, not a guessed civil offset.
	dst := fullInput("PRIVATE")
	start := time.Date(2026, 11, 1, 5, 30, 0, 0, time.UTC)
	end := start.Add(time.Hour)
	dst.StartsAt = &start
	dst.EndsAt = &end
	dst.Timezone = ptr("America/New_York")
	got := create(t, h, a, dst)
	if got.EndsAt.Sub(*got.StartsAt) != time.Hour || *got.Timezone != "America/New_York" {
		t.Fatal("persisted DST")
	}
	// The database duration constraint must use elapsed hours, independent of
	// the SQL session timezone across the spring-forward boundary.
	tx, err := pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(context.Background(), "SET LOCAL TIME ZONE 'America/New_York'"); err != nil {
		t.Fatal(err)
	}
	start = time.Date(2027, 3, 1, 12, 0, 0, 0, time.UTC)
	end = start.Add(31 * 24 * time.Hour)
	if _, err = tx.Exec(context.Background(), "UPDATE experiences.experiences SET starts_at=$2,ends_at=$3 WHERE id=$1", got.ID, start, end); err != nil {
		t.Fatal("elapsed duration across DST", err)
	}
}

func imageBytes(t *testing.T, red uint8) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, 3, 2))
	img.Set(0, 0, color.NRGBA{R: red, A: 255})
	var b bytes.Buffer
	if e := png.Encode(&b, img); e != nil {
		t.Fatal(e)
	}
	return b.Bytes()
}
func upload(t *testing.T, authorization media.Authorization, b []byte, change func(map[string]string)) int {
	t.Helper()
	fields := map[string]string{}
	for k, v := range authorization.Fields {
		fields[k] = v
	}
	if change != nil {
		change(fields)
	}
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	for k, v := range fields {
		if e := w.WriteField(k, v); e != nil {
			t.Fatal(e)
		}
	}
	part, e := w.CreateFormFile("file", "cover.png")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = part.Write(b); e != nil {
		t.Fatal(e)
	}
	if e = w.Close(); e != nil {
		t.Fatal(e)
	}
	req, e := http.NewRequest("POST", authorization.URL, &body)
	if e != nil {
		t.Fatal(e)
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	res, e := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if e != nil {
		t.Fatal("S3 upload transport failed")
	}
	defer res.Body.Close()
	_, _ = io.Copy(io.Discard, res.Body)
	return res.StatusCode
}
func initUpload(t *testing.T, h *harness, a actor, b []byte) media.Initiated {
	r := h.call(t, "POST", "/v1/media/uploads", a, media.InitiateRequest{ContentType: "image/png", SizeBytes: int64(len(b))}, map[string]string{"Idempotency-Key": uuid.NewString()}, 201)
	var out media.Initiated
	if e := json.Unmarshal(r.raw, &out); e != nil {
		t.Fatal(e)
	}
	return out
}
func TestRealS3CoverOwnershipConfirmationAndCleanup(t *testing.T) {
	h := newHarness(t)
	a, b := user(t, true), user(t, true)
	raw := imageBytes(t, 100)
	init := initUpload(t, h, a, raw)
	if _, err := pool.Exec(context.Background(), "UPDATE media.uploads SET status='READY',confirmed_at=now() WHERE id=$1", init.MediaID); err == nil {
		t.Fatal("database accepted READY without verified metadata")
	}
	if init.Upload.Method != "POST" || time.Until(init.Upload.ExpiresAt) > 5*time.Minute {
		t.Fatal("temporary authorization")
	}
	h.call(t, "POST", "/v1/media/uploads/"+init.MediaID+"/confirm", b, struct{}{}, nil, 404)
	in := fullInput("PRIVATE")
	in.CoverMediaID = &init.MediaID
	code(t, h.call(t, "POST", "/v1/experiences", a, in, map[string]string{"Idempotency-Key": uuid.NewString()}, 422), "media_not_ready")
	if status := upload(t, init.Upload, raw, func(f map[string]string) { f["Content-Type"] = "image/jpeg" }); status < 400 {
		t.Fatal("S3 accepted wrong MIME", status)
	}
	if status := upload(t, init.Upload, append(raw, 1), nil); status < 400 {
		t.Fatal("S3 accepted wrong size", status)
	}
	if status := upload(t, init.Upload, raw, func(f map[string]string) { f["key"] = "verified/unauthorized" }); status < 400 {
		t.Fatal("S3 allowed final key", status)
	}
	if status := upload(t, init.Upload, raw, nil); status != 204 && status != 201 && status != 200 {
		t.Fatal("real S3 upload failed", status)
	}
	confirmed := h.call(t, "POST", "/v1/media/uploads/"+init.MediaID+"/confirm", a, struct{}{}, nil, 200)
	repeat := h.call(t, "POST", "/v1/media/uploads/"+init.MediaID+"/confirm", a, struct{}{}, nil, 200)
	if !bytes.Equal(confirmed.raw, repeat.raw) {
		t.Fatal("idempotent confirmation")
	}
	code(t, h.call(t, "POST", "/v1/experiences", b, in, map[string]string{"Idempotency-Key": uuid.NewString()}, 422), "media_not_ready")
	e := create(t, h, a, in)
	h.call(t, "GET", "/v1/experiences/"+e.ID+"/cover", b, nil, nil, 404)
	cover := h.call(t, "GET", "/v1/experiences/"+e.ID+"/cover", a, nil, nil, 200)
	if cover.header.Get("Content-Type") != "image/png" || len(cover.raw) == 0 {
		t.Fatal("verified image")
	}
	// Storage itself denies unauthenticated reads, even knowing the object key.
	publicURL := strings.TrimSuffix(os.Getenv("MEDIA_S3_ENDPOINT"), "/") + "/" + bucket + "/verified/" + init.MediaID
	response, err := (&http.Client{Timeout: 5 * time.Second}).Get(publicURL)
	if err != nil {
		t.Fatal("anonymous S3 check unavailable")
	}
	_ = response.Body.Close()
	if response.StatusCode != 403 && response.StatusCode != 401 {
		t.Fatal("bucket not private", response.StatusCode)
	}
	// Reusable staging capability cannot overwrite the verified image.
	if _, err := store.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("staging/" + init.MediaID), Body: bytes.NewReader(imageBytes(t, 200))}); err != nil {
		t.Fatal("test overwrite failed")
	}
	again := h.call(t, "GET", "/v1/experiences/"+e.ID+"/cover", a, nil, nil, 200)
	if !bytes.Equal(cover.raw, again.raw) {
		t.Fatal("READY object changed")
	}
	fake := []byte("<svg>untrusted</svg>")
	invalid := initUpload(t, h, a, fake)
	if status := upload(t, invalid.Upload, fake, nil); status >= 400 {
		t.Fatal("S3 upload fixture", status)
	}
	code(t, h.call(t, "POST", "/v1/media/uploads/"+invalid.MediaID+"/confirm", a, struct{}{}, nil, 422), "media_invalid")
	abandoned := initUpload(t, h, a, raw)
	if status := upload(t, abandoned.Upload, raw, nil); status >= 400 {
		t.Fatal("S3 abandoned fixture", status)
	}
	exec(t, "UPDATE media.uploads SET created_at=now()-interval '2 days',expires_at=now()-interval '2 days' WHERE id IN ($1,$2,$3)", init.MediaID, invalid.MediaID, abandoned.MediaID)
	if _, err := h.media.Cleanup(context.Background()); err != nil {
		t.Fatal("cleanup", err)
	}
	var status string
	if err := pool.QueryRow(context.Background(), "SELECT status FROM media.uploads WHERE id=$1", abandoned.MediaID).Scan(&status); err != nil || status != "DELETED" {
		t.Fatal("orphan tombstone", err, status)
	}
	if _, err := store.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("staging/" + abandoned.MediaID)}); err == nil {
		t.Fatal("abandoned staging survived")
	}
	if _, err := store.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("verified/" + init.MediaID)}); err != nil {
		t.Fatal("bound cover deleted")
	}
	h.call(t, "GET", "/v1/experiences/"+e.ID+"/cover", a, nil, nil, 200)
	expired := initUpload(t, h, a, raw)
	exec(t, "UPDATE media.uploads SET expires_at=now()-interval '1 second' WHERE id=$1", expired.MediaID)
	code(t, h.call(t, "POST", "/v1/media/uploads/"+expired.MediaID+"/confirm", a, struct{}{}, nil, 410), "upload_expired")
}
