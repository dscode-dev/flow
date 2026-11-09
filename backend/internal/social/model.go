// Package social owns publications and the social graph, never Identity accounts
// or Experience attendance. Authorization is shared by SQL reads and commands.
package social

import (
	"crypto/hmac"
	"crypto/sha256"
	"flow.local/backend/internal/identity"
	"fmt"
	"strconv"
	"time"
)

var ErrConflict = &identity.Failure{Code: "idempotency_conflict", Status: 409}
var ErrVersion = &identity.Failure{Code: "version_conflict", Status: 412}
var ErrPrecondition = &identity.Failure{Code: "precondition_required", Status: 428}
var ErrContent = &identity.Failure{Code: "social_content_invalid", Status: 422}

type Config struct {
	Key                                              []byte
	BodyLimit, MediaLimit, MutationMinute, EditHours int
}

func ParseConfig(get func(string) string, key []byte) (Config, error) {
	c := Config{}
	if len(key) != 32 {
		return c, fmt.Errorf("chave Social inválida")
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte("flow.social.v1"))
	c.Key = m.Sum(nil)
	for _, p := range []struct {
		k           string
		d, min, max int
		v           *int
	}{{"SOCIAL_BODY_LIMIT", 3000, 1, 5000, &c.BodyLimit}, {"SOCIAL_MEDIA_LIMIT", 4, 1, 4, &c.MediaLimit}, {"SOCIAL_MUTATION_MINUTE", 30, 5, 120, &c.MutationMinute}, {"SOCIAL_EDIT_HOURS", 24, 1, 168, &c.EditHours}} {
		n := p.d
		if s := get(p.k); s != "" {
			v, e := strconv.Atoi(s)
			if e != nil {
				return c, fmt.Errorf("%s inválido", p.k)
			}
			n = v
		}
		if n < p.min || n > p.max {
			return c, fmt.Errorf("%s inválido", p.k)
		}
		*p.v = n
	}
	return c, nil
}

type Input struct {
	Context      string   `json:"context"`
	Visibility   string   `json:"visibility"`
	ExperienceID *string  `json:"experience_id"`
	Body         string   `json:"body"`
	MediaIDs     []string `json:"media_ids"`
}
type Report struct {
	TargetType string `json:"target_type"`
	TargetID   string `json:"target_id"`
	Reason     string `json:"reason"`
}
type Page struct {
	Items      []map[string]any `json:"items"`
	NextCursor *string          `json:"next_cursor"`
	AsOf       time.Time        `json:"as_of"`
	ValidUntil time.Time        `json:"valid_until"`
}
type Limits struct {
	Body         int `json:"body_limit"`
	Media        int `json:"media_limit"`
	EditHours    int `json:"edit_hours"`
	VideoSeconds int `json:"video_seconds"`
}

func (s *Service) Limits() Limits {
	return Limits{s.config.BodyLimit, s.config.MediaLimit, s.config.EditHours, 15}
}
