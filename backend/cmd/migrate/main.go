package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "migration failed (verifique configuração e banco)")
		os.Exit(1)
	}
}
func run() error {
	if len(os.Args) != 2 || (os.Args[1] != "up" && os.Args[1] != "down" && os.Args[1] != "status") {
		return fmt.Errorf("usage: migrate up|down|status")
	}
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return fmt.Errorf("DATABASE_URL required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(2)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	dir := os.Getenv("MIGRATIONS_DIR")
	if dir == "" {
		dir = "migrations"
	}
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	return goose.RunContext(ctx, os.Args[1], db, dir)
}
