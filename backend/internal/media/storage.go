// Package media owns verified cover objects and their storage lifecycle.
package media

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const MaxBytes int64 = 5 * 1024 * 1024

var (
	ErrInvalid     = &identity.Failure{Code: "media_invalid", Status: 422}
	ErrPending     = &identity.Failure{Code: "upload_not_pending", Status: 409}
	ErrExpired     = &identity.Failure{Code: "upload_expired", Status: 410}
	ErrUnavailable = &identity.Failure{Code: "media_unavailable", Status: 503}
	ErrOwnership   = &identity.Failure{Code: "media_not_ready", Status: 422}
	ErrConflict    = &identity.Failure{Code: "idempotency_conflict", Status: 409}
)

type Storage struct {
	internal, public *s3.Client
	bucket           string
}
type StorageConfig struct {
	Endpoint, PublicEndpoint, Region, Bucket, AccessKey, SecretKey, SessionToken string
	Production                                                                   bool
}

func ParseStorageConfig(get func(string) string) (StorageConfig, error) {
	c := StorageConfig{Endpoint: get("MEDIA_S3_ENDPOINT"), PublicEndpoint: get("MEDIA_S3_PUBLIC_ENDPOINT"), Region: get("MEDIA_S3_REGION"), Bucket: get("MEDIA_S3_BUCKET"), AccessKey: get("MEDIA_S3_ACCESS_KEY"), SecretKey: get("MEDIA_S3_SECRET_KEY"), SessionToken: get("MEDIA_S3_SESSION_TOKEN"), Production: get("FLOW_ENV") == "production"}
	if c.Endpoint == "" && c.PublicEndpoint == "" && c.Bucket == "" && c.AccessKey == "" && c.SecretKey == "" && c.Region == "" {
		return c, nil
	}
	if c.PublicEndpoint == "" {
		c.PublicEndpoint = c.Endpoint
	}
	if c.Endpoint == "" || c.Bucket == "" || c.Region == "" || c.AccessKey == "" || c.SecretKey == "" {
		return c, errors.New("configuração S3 incompleta")
	}
	for _, v := range []string{c.Endpoint, c.PublicEndpoint} {
		u, e := url.Parse(v)
		if e != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || (u.Scheme != "https" && (u.Scheme != "http" || c.Production)) {
			return c, errors.New("endpoint S3 inválido")
		}
	}
	if len(c.Bucket) < 3 || len(c.Bucket) > 63 || strings.ContainsAny(c.Bucket, "/: ") {
		return c, errors.New("bucket S3 inválido")
	}
	return c, nil
}
func NewStorage(c StorageConfig) *Storage {
	if c.Endpoint == "" {
		return nil
	}
	client := func(endpoint string) *s3.Client {
		return s3.NewFromConfig(aws.Config{Region: c.Region, Credentials: credentials.NewStaticCredentialsProvider(c.AccessKey, c.SecretKey, c.SessionToken), HTTPClient: &http.Client{Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, RetryMaxAttempts: 1}, func(o *s3.Options) {
			o.BaseEndpoint = aws.String(endpoint)
			o.UsePathStyle = true
			o.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
			o.ResponseChecksumValidation = aws.ResponseChecksumValidationWhenRequired
		})
	}
	return &Storage{client(c.Endpoint), client(c.PublicEndpoint), c.Bucket}
}

type Authorization struct {
	Method    string            `json:"method"`
	URL       string            `json:"url"`
	Fields    map[string]string `json:"fields"`
	ExpiresAt time.Time         `json:"expires_at"`
}

func (s *Storage) authorize(ctx context.Context, key, ct string, size int64, expiry time.Time) (Authorization, error) {
	if s == nil {
		return Authorization{}, ErrUnavailable
	}
	out, e := s3.NewPresignClient(s.public).PresignPostObject(ctx, &s3.PutObjectInput{Bucket: &s.bucket, Key: &key}, func(o *s3.PresignPostOptions) {
		o.Expires = time.Until(expiry)
		o.Conditions = []any{[]any{"content-length-range", size, size}, map[string]string{"Content-Type": ct}}
	})
	if e != nil {
		return Authorization{}, ErrUnavailable
	}
	out.Values["Content-Type"] = ct
	return Authorization{"POST", out.URL, out.Values, expiry}, nil
}
func (s *Storage) read(ctx context.Context, key string, limit int64) ([]byte, string, error) {
	if s == nil {
		return nil, "", ErrUnavailable
	}
	out, e := s.internal.GetObject(ctx, &s3.GetObjectInput{Bucket: &s.bucket, Key: &key})
	if e != nil {
		return nil, "", ErrUnavailable
	}
	defer out.Body.Close()
	if out.ContentLength == nil || *out.ContentLength > limit || *out.ContentLength < 1 {
		return nil, "", ErrInvalid
	}
	b, e := io.ReadAll(io.LimitReader(out.Body, limit+1))
	if e != nil {
		return nil, "", ErrUnavailable
	}
	if int64(len(b)) > limit {
		return nil, "", ErrInvalid
	}
	return b, aws.ToString(out.ContentType), nil
}
func (s *Storage) write(ctx context.Context, key, ct string, b []byte) error {
	if s == nil {
		return ErrUnavailable
	}
	_, e := s.internal.PutObject(ctx, &s3.PutObjectInput{Bucket: &s.bucket, Key: &key, Body: bytes.NewReader(b), ContentType: &ct, ContentLength: aws.Int64(int64(len(b))), CacheControl: aws.String("private, no-store")})
	if e != nil {
		return ErrUnavailable
	}
	return nil
}
func (s *Storage) remove(ctx context.Context, key string) error {
	if s == nil {
		return ErrUnavailable
	}
	_, e := s.internal.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &s.bucket, Key: &key})
	if e != nil {
		return ErrUnavailable
	}
	return nil
}
