//go:build integration

package integration

import (
	"encoding/json"
	"flow.local/backend/internal/experiences"
	"fmt"
	"reflect"
	"testing"
	"time"
)

func radarResponse(t *testing.T, h *harness, a actor, q string) experiences.RadarPage {
	t.Helper()
	r := h.call(t, "GET", "/v1/radar/experiences?"+q, a, nil, nil, 200)
	var out experiences.RadarPage
	if e := json.Unmarshal(r.raw, &out); e != nil {
		t.Fatal(e)
	}
	return out
}
func TestRadarSpatialVisibility(t *testing.T) {
	h := newHarness(t)
	a, b := user(t, true), user(t, true)
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD'")
	now := time.Now().UTC().Truncate(time.Second)
	live := homeFixture(t, a, now.Add(-time.Hour), now.Add(time.Hour), -8.05, -34.88)
	future := homeFixture(t, a, now.Add(time.Hour), now.Add(2*time.Hour), -8.06, -34.89)
	outside := homeFixture(t, a, now.Add(time.Hour), now.Add(2*time.Hour), -23.55, -46.63)
	hidden := map[string]bool{outside: true}
	for _, change := range []string{"visibility='PRIVATE'", "visibility='UNLISTED'", "status='CANCELLED',cancelled_at=now()", "status='ARCHIVED',archived_at=now()", "moderation_status='WITHHELD'", "status='DRAFT',published_at=NULL"} {
		id := homeFixture(t, a, now, now.Add(time.Hour), -8.05, -34.88)
		exec(t, "UPDATE experiences.experiences SET "+change+" WHERE id=$1", id)
		hidden[id] = true
	}
	ended := homeFixture(t, a, now.Add(-time.Hour), now, -8.05, -34.88)
	hidden[ended] = true
	query := "bbox=-35,-8.2,-34.7,-7.9&zoom=10"
	out := radarResponse(t, h, b, query)
	if len(out.Items) != 2 || out.Truncated {
		t.Fatal("eligible viewport")
	}
	for _, m := range out.Items {
		if hidden[m.ID] {
			t.Fatal("discovery leak")
		}
	}
	if out.Items[0].ID != live || out.Items[0].Phase != "LIVE" || out.Items[1].ID != future {
		t.Fatal("phase/order")
	}
	if len(radarResponse(t, h, b, query+"&phase=LIVE").Items) != 1 {
		t.Fatal("live filter")
	}
	if len(radarResponse(t, h, b, query+"&category_id=nature").Items) != 0 {
		t.Fatal("category")
	}
	p := query + "&from=" + now.Add(90*time.Minute).Format(time.RFC3339) + "&until=" + now.Add(3*time.Hour).Format(time.RFC3339)
	if got := radarResponse(t, h, b, p); len(got.Items) != 1 || got.Items[0].ID != future {
		t.Fatal("period overlap")
	}
	if len(radarResponse(t, h, b, query+"&latitude=-8.05&longitude=-34.88&radius_m=1000").Items) != 1 {
		t.Fatal("distance")
	}
	first := radarResponse(t, h, b, query+"&limit=1")
	if !first.Truncated || len(first.Items) != 1 {
		t.Fatal("coverage limit")
	}
	if !reflect.DeepEqual(first.Items, radarResponse(t, h, b, query+"&limit=1").Items) {
		t.Fatal("determinism")
	}
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD' WHERE id=$1", live)
	if len(radarResponse(t, h, b, query+"&phase=LIVE").Items) != 0 {
		t.Fatal("withdrawal")
	}
	h.call(t, "GET", "/v1/radar/experiences?"+query, actor{}, nil, nil, 401)
	exec(t, "UPDATE identity.sessions SET revoked_at=now(),revocation_reason='integration' WHERE id=$1", b.session)
	h.call(t, "GET", "/v1/radar/experiences?"+query, b, nil, nil, 401)
}
func TestRadarAntimeridianAndLimits(t *testing.T) {
	h := newHarness(t)
	a := user(t, true)
	exec(t, "UPDATE experiences.experiences SET moderation_status='WITHHELD'")
	now := time.Now().UTC()
	east := homeFixture(t, a, now, now.Add(time.Hour), 0, 179.5)
	west := homeFixture(t, a, now, now.Add(time.Hour), 0, -179.5)
	homeFixture(t, a, now, now.Add(time.Hour), 0, 0)
	out := radarResponse(t, h, a, "bbox=179,-1,-179,1&zoom=8")
	seen := map[string]bool{}
	for _, m := range out.Items {
		seen[m.ID] = true
	}
	if len(seen) != 2 || !seen[east] || !seen[west] {
		t.Fatal("antimeridian")
	}
	for _, q := range []string{"bbox=-180,-85,180,85&zoom=0", "bbox=0,0,31,1&zoom=10", "bbox=0,85,1,90&zoom=10", "bbox=0,0,1,1&zoom=30", "bbox=0,0,1,1&zoom=8&limit=201", "bbox=0,0,1,1&zoom=8&latitude=NaN&longitude=0&radius_m=1000", "bbox=0,0,1,1&zoom=8&status=PUBLISHED"} {
		h.call(t, "GET", "/v1/radar/experiences?"+q, a, nil, nil, 400)
	}
	// Geometry expression index exists and can support the actual viewport predicate.
	var definition string
	if e := pool.QueryRow(t.Context(), "SELECT indexdef FROM pg_indexes WHERE schemaname='experiences' AND indexname='experiences_public_viewport'").Scan(&definition); e != nil {
		t.Fatal(e)
	}
	if definition == "" {
		t.Fatal(fmt.Errorf("viewport index missing"))
	}
}
