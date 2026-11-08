package media

import (
	"context"
	"io"
	"regexp"

	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

type Stream struct {
	Body         io.ReadCloser
	ContentType  string
	Length       int64
	ContentRange string
}

func (s *Storage) open(ctx context.Context, key, rangeHeader string) (Stream, error) {
	var out Stream
	if s == nil {
		return out, ErrUnavailable
	}
	if rangeHeader != "" && !regexp.MustCompile(`^bytes=([0-9]{1,10}-[0-9]{0,10}|-[0-9]{1,10})$`).MatchString(rangeHeader) {
		return out, ErrInvalid
	}
	in := &s3.GetObjectInput{Bucket: &s.bucket, Key: &key}
	if rangeHeader != "" {
		in.Range = &rangeHeader
	}
	r, e := s.internal.GetObject(ctx, in)
	if e != nil {
		return out, ErrUnavailable
	}
	if r.ContentLength == nil || *r.ContentLength < 0 || *r.ContentLength > 32*1024*1024 {
		r.Body.Close()
		return out, ErrInvalid
	}
	return Stream{r.Body, aws.ToString(r.ContentType), *r.ContentLength, aws.ToString(r.ContentRange)}, nil
}
func (s *Service) StreamFlow(ctx context.Context, aid string, poster bool, rangeHeader string) (Stream, error) {
	u, e := dbgen.New(s.pool).GetFlowAsset(ctx, id(aid))
	if e != nil || u.Status != "READY" {
		return Stream{}, ErrOwnership
	}
	key := u.ObjectKey
	if poster {
		key = u.PosterKey
	}
	return s.storage.open(ctx, key, rangeHeader)
}
func (s *Service) StreamCover(ctx context.Context, aid, rangeHeader string) (Stream, error) {
	u, e := dbgen.New(s.pool).GetMediaUpload(ctx, id(aid))
	if e != nil || u.Status != "READY" {
		return Stream{}, ErrOwnership
	}
	return s.storage.open(ctx, u.ObjectKey, rangeHeader)
}
