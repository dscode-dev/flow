package main

import (
	"context"
	"errors"
	"flow.local/backend/internal/experiences"
	"flow.local/backend/internal/identity"
	identityhttp "flow.local/backend/internal/identity/transport"
	"flow.local/backend/internal/media"
	"flow.local/backend/internal/platform/config"
	"flow.local/backend/internal/platform/dependencies"
	"flow.local/backend/internal/platform/httpapi"
	"flow.local/backend/internal/platform/telemetry"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

func run(log *slog.Logger) error {
	c, err := config.Load()
	if err != nil {
		return err
	}
	identityConfig, err := identity.ParseConfig(os.Getenv)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	shutdownTrace, err := telemetry.Setup(ctx, c.OTLPEndpoint, log)
	if err != nil {
		return errors.New("falha ao configurar telemetria")
	}
	defer func() {
		t, cancel := context.WithTimeout(context.Background(), c.ShutdownTimeout)
		defer cancel()
		_ = shutdownTrace(t)
	}()
	deps, err := dependencies.Open(ctx, c)
	if err != nil {
		return err
	}
	defer deps.Close()
	var draining atomic.Bool
	identityService := identity.NewService(ctx, deps.Postgres, identityConfig)
	identityHandler := identityhttp.New(identityService)
	experiencesConfig, err := experiences.ParseConfig(os.Getenv, identityConfig.HMACKey)
	if err != nil {
		return err
	}
	storageConfig, err := media.ParseStorageConfig(os.Getenv)
	if err != nil {
		return err
	}
	mediaService := media.New(deps.Postgres, media.NewStorage(storageConfig), experiencesConfig.UploadDaily)
	experiencesHandler := experiences.NewHandler(experiences.New(deps.Postgres, mediaService, experiencesConfig), mediaService, identityHandler)
	server := &http.Server{Addr: c.Address, Handler: httpapi.New(log, deps, c.MaxBodyBytes, c.DependencyTimeout, draining.Load, identityHandler.Register, experiencesHandler.Register), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024}
	done := make(chan error, 1)
	go func() {
		log.Info("api starting", "address", c.Address, "environment", c.Environment)
		done <- server.ListenAndServe()
	}()
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
	}
	draining.Store(true)
	shutdown, cancel := context.WithTimeout(context.Background(), c.ShutdownTimeout)
	defer cancel()
	if err := server.Shutdown(shutdown); err != nil {
		_ = server.Close()
		return errors.New("prazo de encerramento excedido")
	}
	log.Info("api stopped")
	return nil
}
func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("api failed", "reason", err.Error())
		os.Exit(1)
	}
}
