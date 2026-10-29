package identity

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

type bucket struct {
	key    string
	window time.Duration
	max    int
}

func (s *Service) limit(ctx context.Context, buckets []bucket) error {
	sort.Slice(buckets, func(i, j int) bool { return buckets[i].key < buckets[j].key })
	return s.transaction(ctx, func(q *dbgen.Queries) error {
		now := time.Now().UTC()
		for _, b := range buckets {
			start := now.Truncate(b.window)
			key := fmt.Sprintf("%s:%d", b.key, start.Unix())
			_, e := q.IncrementIdentityBucket(ctx, dbgen.IncrementIdentityBucketParams{BucketKey: key, ExpiresAt: ts(start.Add(b.window)), Count: int32(b.max)})
			if errors.Is(e, pgx.ErrNoRows) {
				return ErrRate
			}
			if e != nil {
				return e
			}
		}
		return nil
	})
}
