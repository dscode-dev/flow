package database

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// InTransaction executa um callback atômico. Não publicar no broker dentro dele.
// O chamador usa
// Queries.WithTx(tx) para alteração de domínio e AppendOutbox no mesmo commit.
// No consumidor, RegisterInbox e efeito de domínio compartilham esta transação;
// pgx.ErrNoRows no registro significa mensagem já processada e nenhum novo efeito.
func InTransaction(ctx context.Context, pool *pgxpool.Pool, fn func(pgx.Tx) error) error {
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		_ = tx.Rollback(cleanup)
	}()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
