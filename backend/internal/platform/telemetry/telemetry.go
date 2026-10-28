package telemetry

import (
	"context"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"log/slog"
	"net/url"
)

func Setup(ctx context.Context, endpoint string, log *slog.Logger) (func(context.Context) error, error) {
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(error) { log.Error("telemetry export failed") }))
	opts := []sdktrace.TracerProviderOption{sdktrace.WithResource(resource.NewSchemaless(attribute.String("service.name", "flow-api"))), sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(0.1)))}
	if endpoint != "" {
		// OTEL_EXPORTER_OTLP_ENDPOINT é a base; WithEndpointURL espera a URL
		// específica do sinal, incluindo /v1/traces.
		traceURL, err := url.JoinPath(endpoint, "v1/traces")
		if err != nil {
			return nil, err
		}
		exporter, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(traceURL))
		if err != nil {
			return nil, err
		}
		opts = append(opts, sdktrace.WithBatcher(exporter))
	}
	provider := sdktrace.NewTracerProvider(opts...)
	otel.SetTracerProvider(provider)
	return provider.Shutdown, nil
}
