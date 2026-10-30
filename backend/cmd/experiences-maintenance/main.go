package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"flow.local/backend/internal/experiences"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/media"
	"github.com/jackc/pgx/v5/pgxpool"
)

func run() error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	ic, e := identity.ParseConfig(os.Getenv)
	if e != nil {
		return e
	}
	ec, e := experiences.ParseConfig(os.Getenv, ic.HMACKey)
	if e != nil {
		return e
	}
	sc, e := media.ParseStorageConfig(os.Getenv)
	if e != nil {
		return e
	}
	pool, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if e != nil {
		return identity.ErrStorage
	}
	defer pool.Close()
	m := media.New(pool, media.NewStorage(sc), ec.UploadDaily)
	count, e := m.Cleanup(ctx)
	if e != nil {
		return identity.ErrStorage
	}
	if e = experiences.New(pool, m, ec).Cleanup(ctx); e != nil {
		return identity.ErrStorage
	}
	slog.Info("experiences maintenance completed", "media_checked", count)
	return nil
}
func main() {
	if run() != nil {
		slog.Error("experiences maintenance failed")
		os.Exit(1)
	}
}
