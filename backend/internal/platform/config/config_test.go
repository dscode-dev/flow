package config

import (
	"strings"
	"testing"
)

func base() map[string]string {
	return map[string]string{"DATABASE_URL": "postgres://flow:secret@database/flow?sslmode=disable", "REDIS_URL": "redis://:secret@cache:6379/0", "RABBITMQ_URL": "amqp://flow:secret@broker:5672/"}
}
func TestValidation(t *testing.T) {
	for _, tc := range []struct{ name, key, value string }{
		{"missing database", "DATABASE_URL", ""}, {"bad redis", "REDIS_URL", "http://cache"}, {"invalid size", "HTTP_MAX_BODY_BYTES", "0"}, {"negative deadline", "DEPENDENCY_TIMEOUT", "-1s"}, {"environment", "FLOW_ENV", "prod"}, {"insecure production", "FLOW_ENV", "production"}, {"OTLP endpoint", "OTEL_EXPORTER_OTLP_ENDPOINT", "invalid"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := base()
			env[tc.key] = tc.value
			_, err := Parse(func(k string) string { return env[k] })
			if err == nil {
				t.Fatal("expected validation failure")
			}
			if strings.Contains(err.Error(), "secret") {
				t.Fatal("credential leaked")
			}
		})
	}
	env := base()
	if _, err := Parse(func(k string) string { return env[k] }); err != nil {
		t.Fatal(err)
	}
	env["FLOW_ENV"] = "production"
	env["DATABASE_URL"] = "postgres://flow:secret@database/flow?sslmode=verify-full"
	env["REDIS_URL"] = "rediss://:secret@cache:6379"
	env["RABBITMQ_URL"] = "amqps://flow:secret@broker:5671/"
	if _, err := Parse(func(k string) string { return env[k] }); err != nil {
		t.Fatal(err)
	}
}
