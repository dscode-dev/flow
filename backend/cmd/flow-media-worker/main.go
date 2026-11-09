// flow-media-worker is part of the same Go backend; durable jobs live in Postgres.
package main

import (
	"context"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5/pgxpool"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

func run() error {
	for _, name := range []string{"ffmpeg", "ffprobe"} {
		if _, e := exec.LookPath(name); e != nil {
			return e
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	c, e := media.ParseFlowConfig(os.Getenv)
	if e != nil {
		return e
	}
	sc, e := media.ParseStorageConfig(os.Getenv)
	if e != nil {
		return e
	}
	p, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if e != nil {
		return e
	}
	defer p.Close()
	m := media.New(p, media.NewStorage(sc), 30)
	m.ConfigureFlows(c)
	idle := time.NewTicker(2 * time.Second)
	defer idle.Stop()
	maintenance := time.Now()
	for ctx.Err() == nil {
		worked, e := m.ProcessFlowNext(ctx)
		if e != nil && ctx.Err() == nil {
			slog.Error("flow media job unavailable")
		}
		if time.Since(maintenance) > time.Minute {
			e := dbgen.New(p).SocialCleanup(ctx)
			if e != nil {
				slog.Error("social maintenance unavailable")
			}
			n, e := m.CleanupFlows(ctx)
			if e != nil {
				slog.Error("flow media cleanup unavailable")
			} else {
				slog.Info("flow media cleanup", "checked", n)
			}
			maintenance = time.Now()
		}
		if worked && e == nil {
			continue
		}
		select {
		case <-ctx.Done():
			return nil
		case <-idle.C:
		}
	}
	return nil
}
func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if run() != nil {
		slog.Error("flow media worker failed")
		os.Exit(1)
	}
}
