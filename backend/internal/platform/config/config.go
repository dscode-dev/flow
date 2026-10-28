package config

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Environment, Address, DatabaseURL, RedisURL, RabbitURL, OTLPEndpoint string
	MaxBodyBytes                                                         int64
	DependencyTimeout, ShutdownTimeout                                   time.Duration
}

func Load() (Config, error) { return Parse(os.Getenv) }

func Parse(get func(string) string) (Config, error) {
	value := func(k, fallback string) string {
		if v := get(k); v != "" {
			return v
		}
		return fallback
	}
	c := Config{Environment: value("FLOW_ENV", "development"), Address: value("HTTP_ADDR", ":8080"), DatabaseURL: get("DATABASE_URL"), RedisURL: get("REDIS_URL"), RabbitURL: get("RABBITMQ_URL"), OTLPEndpoint: get("OTEL_EXPORTER_OTLP_ENDPOINT")}
	if c.Environment != "development" && c.Environment != "test" && c.Environment != "production" {
		return c, fmt.Errorf("FLOW_ENV inválido")
	}
	if _, _, err := net.SplitHostPort(c.Address); err != nil {
		return c, fmt.Errorf("HTTP_ADDR inválido")
	}
	for _, item := range []struct {
		key, raw string
		schemes  []string
	}{
		{"DATABASE_URL", c.DatabaseURL, []string{"postgres", "postgresql"}}, {"REDIS_URL", c.RedisURL, []string{"redis", "rediss"}}, {"RABBITMQ_URL", c.RabbitURL, []string{"amqp", "amqps"}},
	} {
		u, err := url.Parse(item.raw)
		valid := false
		if err == nil && u.Hostname() != "" {
			for _, s := range item.schemes {
				if u.Scheme == s {
					valid = true
				}
			}
		}
		if !valid {
			return c, fmt.Errorf("%s ausente ou inválido", item.key)
		}
		if c.Environment == "production" {
			if item.key == "DATABASE_URL" && u.Query().Get("sslmode") != "verify-full" {
				return c, fmt.Errorf("DATABASE_URL exige sslmode=verify-full em produção")
			}
			if item.key == "REDIS_URL" && u.Scheme != "rediss" {
				return c, fmt.Errorf("REDIS_URL exige TLS em produção")
			}
			if item.key == "RABBITMQ_URL" && u.Scheme != "amqps" {
				return c, fmt.Errorf("RABBITMQ_URL exige TLS em produção")
			}
		}
	}
	if c.OTLPEndpoint != "" {
		u, e := url.Parse(c.OTLPEndpoint)
		if e != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Scheme != "http" && u.Scheme != "https") {
			return c, fmt.Errorf("OTEL_EXPORTER_OTLP_ENDPOINT inválido")
		}
		if c.Environment == "production" && u.Scheme != "https" {
			return c, fmt.Errorf("OTLP exige HTTPS em produção")
		}
	}
	var err error
	c.MaxBodyBytes, err = strconv.ParseInt(value("HTTP_MAX_BODY_BYTES", "1048576"), 10, 64)
	if err != nil || c.MaxBodyBytes < 1 || c.MaxBodyBytes > 16*1024*1024 {
		return c, fmt.Errorf("HTTP_MAX_BODY_BYTES deve estar entre 1 e 16777216")
	}
	c.DependencyTimeout, err = time.ParseDuration(value("DEPENDENCY_TIMEOUT", "2s"))
	if err != nil || c.DependencyTimeout <= 0 || c.DependencyTimeout > 30*time.Second {
		return c, fmt.Errorf("DEPENDENCY_TIMEOUT inválido")
	}
	c.ShutdownTimeout, err = time.ParseDuration(value("SHUTDOWN_TIMEOUT", "10s"))
	if err != nil || c.ShutdownTimeout <= 0 || c.ShutdownTimeout > time.Minute {
		return c, fmt.Errorf("SHUTDOWN_TIMEOUT inválido")
	}
	return c, nil
}
