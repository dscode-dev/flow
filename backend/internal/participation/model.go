// Package participation owns attendance intent, invitations and verified check-in
// for existing Experiences. It runs in the API process and PostgreSQL transaction.
package participation

import (
	"crypto/hmac"
	"crypto/sha256"
	"fmt"
	"strconv"
	"time"

	"flow.local/backend/internal/identity"
)

var (
	ErrInvalid      = identity.ErrInvalid
	ErrState        = &identity.Failure{Code: "participation_transition", Status: 409}
	ErrFull         = &identity.Failure{Code: "capacity_full", Status: 409}
	ErrCapacity     = &identity.Failure{Code: "capacity_below_confirmed", Status: 409}
	ErrVersion      = &identity.Failure{Code: "version_conflict", Status: 412}
	ErrPrecondition = &identity.Failure{Code: "precondition_required", Status: 428}
	ErrKey          = &identity.Failure{Code: "idempotency_conflict", Status: 409}
	ErrInvite       = &identity.Failure{Code: "invitation_unavailable", Status: 404}
	ErrExpired      = &identity.Failure{Code: "invitation_expired", Status: 409}
	ErrCheckin      = &identity.Failure{Code: "checkin_unavailable", Status: 409}
	ErrPrivate      = &identity.Failure{Code: "private_invitation_required", Status: 409}
	ErrCode         = &identity.Failure{Code: "checkin_code_invalid", Status: 422}
	ErrCodeExpired  = &identity.Failure{Code: "checkin_code_expired", Status: 409}
	ErrReplay       = &identity.Failure{Code: "checkin_code_used", Status: 409}
)

type Config struct {
	Key                                                   []byte
	CheckinTTLSeconds, CheckinLeadMinutes, MutationMinute int
}

func ParseConfig(get func(string) string, key []byte) (Config, error) {
	c := Config{}
	for _, p := range []struct {
		k             string
		def, min, max int
		dst           *int
	}{
		{"CHECKIN_TTL_SECONDS", 120, 30, 300, &c.CheckinTTLSeconds},
		{"CHECKIN_LEAD_MINUTES", 30, 0, 120, &c.CheckinLeadMinutes},
		{"PARTICIPATION_MUTATION_MINUTE", 30, 5, 120, &c.MutationMinute},
	} {
		n := p.def
		if v := get(p.k); v != "" {
			var err error
			n, err = strconv.Atoi(v)
			if err != nil {
				return c, fmt.Errorf("%s inválido", p.k)
			}
		}
		if n < p.min || n > p.max {
			return c, fmt.Errorf("%s inválido", p.k)
		}
		*p.dst = n
	}
	if len(key) != 32 {
		return c, fmt.Errorf("chave Participation inválida")
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte("flow.participation.v1"))
	c.Key = m.Sum(nil)
	return c, nil
}

type Settings struct {
	Mode              string `json:"mode"`
	Capacity          *int32 `json:"capacity"`
	ConfirmedCount    int64  `json:"confirmed_count"`
	Version           int64  `json:"version"`
	ExperienceVersion int64  `json:"experience_version"`
	Visibility        string `json:"visibility"`
	CanManage         bool   `json:"can_manage"`
	CanConfigure      bool   `json:"can_configure"`
}

func (s Settings) ETag() string { return fmt.Sprintf("\"%d-%d\"", s.Version, s.ExperienceVersion) }

type SettingsInput struct {
	Mode     string `json:"mode"`
	Capacity *int32 `json:"capacity"`
}
type Summary struct {
	ExperienceID   string      `json:"experience_id"`
	Mode           string      `json:"mode"`
	State          string      `json:"state"`
	Interested     bool        `json:"interested"`
	Version        int64       `json:"version"`
	IsOwner        bool        `json:"is_owner"`
	Eligible       bool        `json:"eligible"`
	Capacity       *int32      `json:"capacity"`
	ConfirmedCount int64       `json:"confirmed_count"`
	Remaining      *int32      `json:"remaining"`
	Actions        []string    `json:"actions"`
	CheckedIn      bool        `json:"checked_in"`
	CheckinOpen    bool        `json:"checkin_open"`
	CheckedAt      *time.Time  `json:"checked_at"`
	Invitation     *Invitation `json:"invitation"`
	ExternalTicket bool        `json:"external_ticket"`
	AsOf           time.Time   `json:"as_of"`
	ValidUntil     time.Time   `json:"valid_until"`
}
type Member struct {
	UserID      string     `json:"user_id"`
	DisplayName string     `json:"display_name"`
	Handle      *string    `json:"handle"`
	State       string     `json:"state"`
	Interested  bool       `json:"interested"`
	Blocked     bool       `json:"blocked"`
	Version     int64      `json:"version"`
	UpdatedAt   time.Time  `json:"updated_at"`
	CheckedIn   bool       `json:"checked_in"`
	CheckedAt   *time.Time `json:"checked_at"`
}
type Invitation struct {
	ID            string    `json:"id"`
	ExperienceID  string    `json:"experience_id"`
	InviteeUserID string    `json:"invitee_user_id"`
	State         string    `json:"state"`
	ExpiresAt     time.Time `json:"expires_at"`
	Version       int64     `json:"version"`
	Expired       bool      `json:"expired"`
}
type InvitationInput struct {
	UserID       string `json:"user_id,omitempty"`
	Handle       string `json:"handle,omitempty"`
	ExpiresHours *int32 `json:"expires_hours,omitempty"`
}
type Credential struct {
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expires_at"`
	AsOf      time.Time `json:"as_of"`
}
type Checkin struct {
	ID           string     `json:"id"`
	ExperienceID string     `json:"experience_id"`
	UserID       string     `json:"user_id"`
	CheckedAt    time.Time  `json:"checked_at"`
	RevokedAt    *time.Time `json:"revoked_at"`
	Version      int64      `json:"version"`
	DisplayName  string     `json:"display_name"`
	Handle       *string    `json:"handle"`
}
type Page struct {
	Items      []map[string]any `json:"items"`
	NextCursor *string          `json:"next_cursor"`
	AsOf       time.Time        `json:"as_of"`
	ValidUntil time.Time        `json:"valid_until"`
}
