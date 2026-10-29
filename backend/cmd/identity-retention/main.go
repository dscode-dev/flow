// identity-retention aplica a política técnica explícita. Não remove contas,
// perfis, identidades/reservas de ownership nem eventos de outbox pendentes.
package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if os.Getenv("DATABASE_URL") == "" {
		log.Error("DATABASE_URL required")
		os.Exit(1)
	}
	pool, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if e != nil {
		log.Error("retention unavailable")
		os.Exit(1)
	}
	defer pool.Close()
	e = database.InTransaction(ctx, pool, func(tx pgx.Tx) error {
		q := dbgen.New(tx)
		for _, run := range []func(context.Context) (int64, error){q.PruneIdentityAccess, q.PruneIdentityChallenges, q.PruneIdentityRateLimits, q.PruneIdentityNotifications, q.PruneIdentitySessionAccess, q.PruneIdentityRefreshHistory, q.PruneIdentityChallengeSessions, q.PruneIdentitySessions, q.PruneIdentityDevices, q.PruneIdentityAudit} {
			if _, e := run(ctx); e != nil {
				return e
			}
		}
		return nil
	})
	if e != nil {
		log.Error("retention failed")
		os.Exit(1)
	}
	log.Info("identity retention completed")
}
