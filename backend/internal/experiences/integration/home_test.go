//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"

	"flow.local/backend/internal/experiences"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
)

// Synthetic content exists only in the isolated integration database.
func homeFixture(t *testing.T, a actor, start, end time.Time, lat, lng float64) string {
	t.Helper()
	id := uuid.NewString()
	exec(t, `INSERT INTO experiences.experiences(id,creator_user_id,title,description,category_id,visibility,status,starts_at,ends_at,timezone,point,venue_name,published_at,created_at)
 VALUES($1,$2,'Encontro de integração','Conteúdo sintético de integração','music','PUBLIC','PUBLISHED',$3,$4,'America/Recife',ST_SetSRID(ST_MakePoint($5,$6),4326)::geography,'Local de integração',now(),$7)`, id, a.user, start, end, lng, lat, start.Add(-24*time.Hour))
	return id
}
func homeResponse(t *testing.T, h *harness, a actor, query string) experiences.Home {
	t.Helper()
	r := h.call(t, "GET", "/v1/home"+query, a, nil, nil, 200)
	var out experiences.Home
	if err := json.Unmarshal(r.raw, &out); err != nil {
		t.Fatal(err)
	}
	if len(r.raw) > 512*1024 {
		t.Fatal("response budget")
	}
	return out
}
func homeSections(h experiences.Home) map[string][]experiences.HomeItem {
	out := map[string][]experiences.HomeItem{}
	for _, s := range h.Sections {
		out[s.ID] = s.Items
	}
	return out
}
func TestHomeDiscovery(t *testing.T) {
	h := newHarness(t)
	a, b := user(t, true), user(t, true)
	// Isolate fixture eligibility from the rest of this package's tests.
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD'")
	now := time.Now().UTC().Truncate(time.Second)
	live := homeFixture(t, a, now.Add(-time.Hour), now.Add(time.Hour), -8.05, -34.88)
	soon := homeFixture(t, a, now.Add(2*time.Hour), now.Add(3*time.Hour), -8.05, -34.88)
	far := homeFixture(t, a, now.Add(72*time.Hour), now.Add(73*time.Hour), -23.55, -46.63)
	blocked := map[string]bool{}
	for _, change := range []string{
		"visibility='PRIVATE'", "visibility='UNLISTED'", "moderation_status='WITHHELD'",
		"status='CANCELLED',cancelled_at=now()", "status='ARCHIVED',archived_at=now()",
		"status='DRAFT',published_at=NULL",
	} {
		id := homeFixture(t, a, now.Add(2*time.Hour), now.Add(3*time.Hour), -8.05, -34.88)
		// change is an internal fixed fixture expression, never request input.
		exec(t, "UPDATE experiences.experiences SET "+change+" WHERE id=$1", id)
		blocked[id] = true
	}
	ended := homeFixture(t, a, now.Add(-2*time.Hour), now.Add(-time.Second), -8.05, -34.88)
	blocked[ended] = true
	without := homeResponse(t, h, b, "")
	if without.Locality != nil || without.SoonHours != 48 || without.DefaultRadiusM != 25000 {
		t.Fatal("no locality/defaults")
	}
	sections := homeSections(without)
	if len(sections["live"]) != 1 || sections["live"][0].Experience.ID != live {
		t.Fatal("live")
	}
	if len(sections["soon"]) != 1 || sections["soon"][0].Experience.ID != soon {
		t.Fatal("soon window")
	}
	for _, s := range without.Sections {
		if s.ID == "nearby" && s.Availability != "locality_required" {
			t.Fatal("locality required")
		}
		for _, item := range s.Items {
			e := item.Experience
			if blocked[e.ID] || e.Visibility != "PUBLIC" || e.Status != "PUBLISHED" || !e.EndsAt.After(without.AsOf) {
				t.Fatal("eligibility leak")
			}
			if s.ID == "live" && (e.StartsAt.After(without.AsOf) || *e.Phase != "LIVE") {
				t.Fatal("authoritative phase")
			}
		}
	}
	near := homeResponse(t, h, b, "?latitude=-8.0476&longitude=-34.877&radius_m=10000")
	if near.Locality.Latitude != -8.05 || near.Locality.Longitude != -34.88 {
		t.Fatal("coarsening")
	}
	nearby := homeSections(near)["nearby"]
	if len(nearby) == 0 {
		t.Fatal("PostGIS nearby empty")
	}
	for _, item := range nearby {
		if item.Experience.ID == far || item.DistanceM == nil || *item.DistanceM > 10000 {
			t.Fatal("radius/distance")
		}
	}
	other := homeResponse(t, h, b, "?latitude=-23.55&longitude=-46.63&radius_m=10000&category_id=music")
	if len(homeSections(other)["nearby"]) != 1 || homeSections(other)["nearby"][0].Experience.ID != far {
		t.Fatal("region change")
	}
	// No cache: withdrawal is reflected in the next composition.
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD' WHERE id=$1", live)
	if len(homeSections(homeResponse(t, h, b, ""))["live"]) != 0 {
		t.Fatal("withdrawal invalidation")
	}
	for _, query := range []string{"limit=0", "limit=7", "limit=NaN", "latitude=NaN&longitude=0", "latitude=0", "longitude=0", "radius_m=1000", "latitude=91&longitude=0", "latitude=0&longitude=0&radius_m=999", "limit=1&limit=2", "unknown=1", "category_id=unknown", "category_id="} {
		h.call(t, "GET", "/v1/home?"+query, b, nil, nil, 400)
	}
	h.call(t, "GET", "/v1/home", actor{}, nil, nil, 401)
	exec(t, "UPDATE identity.sessions SET revoked_at=now(),revocation_reason='integration' WHERE id=$1", b.session)
	h.call(t, "GET", "/v1/home", b, nil, nil, 401)
}

func TestHomeBoundsAndOrdering(t *testing.T) {
	h := newHarness(t)
	a := user(t, true)
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD'")
	now := time.Now().UTC().Truncate(time.Second)
	for i := range 25 {
		homeFixture(t, a, now.Add(time.Hour), now.Add(2*time.Hour), -8.05+float64(i)*0.0001, -34.88)
	}
	query := "?" + url.Values{"latitude": {"-8.05"}, "longitude": {"-34.88"}, "limit": {"4"}}.Encode()
	first := homeResponse(t, h, a, query)
	second := homeResponse(t, h, a, query)
	if !reflect.DeepEqual(first.Sections, second.Sections) {
		t.Fatal("unstable tie ordering")
	}
	seen := map[string]int{}
	total := 0
	for _, s := range first.Sections {
		if len(s.Items) > 4 || (s.ID == "highlights" && len(s.Items) > 1) {
			t.Fatal("section limit")
		}
		for _, item := range s.Items {
			seen[item.Experience.ID]++
			total++
		}
	}
	if total > 21 {
		t.Fatal("total bound")
	}
	for _, count := range seen {
		if count > 2 {
			t.Fatal("repetition")
		}
	}
	// Forced index plans prove the view can use the partial indexes (not a load benchmark).
	tx, err := pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(context.Background(), "SET LOCAL enable_seqscan=off"); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`EXPLAIN SELECT id FROM experiences.discovery WHERE ends_at>now() ORDER BY starts_at,id LIMIT 4`,
		`EXPLAIN SELECT id FROM experiences.discovery WHERE ends_at>now() AND ST_DWithin(point,ST_SetSRID(ST_MakePoint(-34.88,-8.05),4326)::geography,10000) LIMIT 4`,
		`EXPLAIN SELECT id FROM experiences.discovery WHERE ends_at>now() ORDER BY created_at DESC,id DESC LIMIT 4`,
	} {
		rows, e := tx.Query(context.Background(), q)
		if e != nil {
			t.Fatal(e)
		}
		indexed := false
		for rows.Next() {
			var line string
			if e = rows.Scan(&line); e != nil {
				t.Fatal(e)
			}
			if strings.Contains(line, "Index") {
				indexed = true
			}
		}
		rows.Close()
		if rows.Err() != nil || !indexed {
			t.Fatal("discovery index unavailable")
		}
	}
}

func TestHomeTemporalBoundaries(t *testing.T) {
	a := user(t, true)
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD'")
	now := time.Now().UTC().Truncate(time.Second)
	live := homeFixture(t, a, now, now.Add(time.Hour), 0, 0)
	ended := homeFixture(t, a, now.Add(-time.Hour), now, 0, 0)
	future := homeFixture(t, a, now.Add(time.Microsecond), now.Add(time.Hour), 0, 0)
	edge := homeFixture(t, a, now.Add(48*time.Hour), now.Add(49*time.Hour), 0, 0)
	outside := homeFixture(t, a, now.Add(48*time.Hour+time.Microsecond), now.Add(49*time.Hour), 0, 0)
	stamp := func(v time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: v, Valid: true} }
	rows, err := dbgen.New(pool).HomeCandidates(t.Context(), dbgen.HomeCandidatesParams{AsOf: stamp(now), SoonUntil: stamp(now.Add(48 * time.Hour)), SectionLimit: 8, RadiusM: 1000})
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]map[string]bool{}
	for _, row := range rows {
		if seen[row.CSection] == nil {
			seen[row.CSection] = map[string]bool{}
		}
		seen[row.CSection][row.ID.String()] = true
		if row.ID.String() == ended {
			t.Fatal("end equality must be excluded")
		}
	}
	if !seen["live"][live] || seen["live"][future] || !seen["soon"][future] || !seen["soon"][edge] || seen["soon"][outside] {
		t.Fatal("temporal boundaries")
	}
}

func TestHomeCatalogBound(t *testing.T) {
	h := newHarness(t)
	a := user(t, true)
	t.Cleanup(func() { exec(t, "DELETE FROM experiences.categories WHERE id LIKE 'zz_home_%'") })
	for i := range 105 {
		exec(t, "INSERT INTO experiences.categories(id,name,sort_order) VALUES($1,'Categoria sintética de teste',$2)", fmt.Sprintf("zz_home_%03d", i), 10000+i)
	}
	out := homeResponse(t, h, a, "")
	if len(out.Categories) != 100 {
		t.Fatal("catalog must be bounded in SQL")
	}
	h.call(t, "GET", "/v1/home?category_id=zz_home_104", a, nil, nil, 400)
}
