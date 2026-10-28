package dependencies

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"time"

	"flow.local/backend/internal/platform/config"
	"github.com/jackc/pgx/v5/pgxpool"
	amqp "github.com/rabbitmq/amqp091-go"
	"github.com/redis/go-redis/v9"
)

type Dependencies struct {
	Postgres  *pgxpool.Pool
	Redis     *redis.Client
	rabbitURL string
	timeout   time.Duration
}

func Open(ctx context.Context, c config.Config) (*Dependencies, error) {
	pc, err := pgxpool.ParseConfig(c.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("configuração PostgreSQL inválida")
	}
	pc.MaxConns = 10
	pc.MinConns = 0
	pc.ConnConfig.ConnectTimeout = c.DependencyTimeout
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("não foi possível criar pool PostgreSQL")
	}
	rc, err := redis.ParseURL(c.RedisURL)
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf("configuração Redis inválida")
	}
	rc.DialTimeout = c.DependencyTimeout
	rc.ReadTimeout = c.DependencyTimeout
	rc.WriteTimeout = c.DependencyTimeout
	rc.MaxRetries = -1
	return &Dependencies{Postgres: pool, Redis: redis.NewClient(rc), rabbitURL: c.RabbitURL, timeout: c.DependencyTimeout}, nil
}

// Cada probe AMQP estabelece uma conexão autenticada limitada por deadline e a fecha.
// Não declara filas nem presume que um consumidor de negócio existe.
func (d *Dependencies) rabbit(ctx context.Context) error {
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(d.timeout)
	}
	conn, err := amqp.DialConfig(d.rabbitURL, amqp.Config{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, Dial: func(network, address string) (net.Conn, error) {
		c, e := (&net.Dialer{Timeout: d.timeout}).DialContext(ctx, network, address)
		if e == nil {
			_ = c.SetDeadline(deadline)
		}
		return c, e
	}})
	if err != nil {
		return err
	}
	return conn.Close()
}

func (d *Dependencies) Check(ctx context.Context) map[string]bool {
	type result struct {
		name string
		ok   bool
	}
	ch := make(chan result, 3)
	for name, check := range map[string]func(context.Context) error{"postgres": d.Postgres.Ping, "redis": func(c context.Context) error { return d.Redis.Ping(c).Err() }, "rabbitmq": d.rabbit} {
		go func() {
			c, cancel := context.WithTimeout(ctx, d.timeout)
			defer cancel()
			ch <- result{name, check(c) == nil}
		}()
	}
	out := map[string]bool{}
	for range 3 {
		r := <-ch
		out[r.name] = r.ok
	}
	return out
}
func (d *Dependencies) Close() { _ = d.Redis.Close(); d.Postgres.Close() }
