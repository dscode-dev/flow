package experiences

import (
	"context"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// ChangeCapacity is used only after Participation has locked the Experience and
// checked owner, lifecycle, optimistic version and confirmed seat count. It keeps
// the existing Experience audit/version/outbox authoritative for this attribute.
func ChangeCapacity(ctx context.Context, tx pgx.Tx, eid, actor string, capacity *int32, request string) error {
	q := dbgen.New(tx)
	var n pgtype.Int4
	if capacity != nil {
		n = pgtype.Int4{Int32: int32(*capacity), Valid: true}
	}
	if err := q.UpdateExperienceCapacity(ctx, dbgen.UpdateExperienceCapacityParams{ID: id(eid), Capacity: n}); err != nil {
		return err
	}
	r, err := load(ctx, q, eid)
	if err != nil {
		return err
	}
	return emit(ctx, q, r.Experience, actor, "experience.capacity_updated", request)
}
