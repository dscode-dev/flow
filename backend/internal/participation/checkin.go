package participation

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

var codePattern = regexp.MustCompile(`^[A-Z2-7]{16}$`)

func (s *Service) codeHash(eid, code string) []byte {
	m := hmac.New(sha256.New, s.config.Key)
	m.Write([]byte("checkin:" + eid + ":" + code))
	return m.Sum(nil)
}
func (s *Service) checkinWindow(c state) bool {
	return c.open() && c.e.StartsAt != nil && !c.now.Before(c.e.StartsAt.Add(-time.Duration(s.config.CheckinLeadMinutes)*time.Minute))
}
func (s *Service) IssueCredential(ctx context.Context, a *identity.Session, eid, request string) (json.RawMessage, error) {
	return s.run(ctx, a, eid, "", "checkin.issue", request, nil, true, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if c.owner(a.UserID) || !s.checkinWindow(c) {
			return nil, ErrCheckin
		}
		m, err := member(ctx, q, eid, a.UserID)
		if err != nil {
			return nil, err
		}
		if m.State != "CONFIRMED" || m.Blocked {
			return nil, ErrCheckin
		}
		prior, err := q.GetParticipationCheckin(ctx, dbgen.GetParticipationCheckinParams{ExperienceID: id(eid), UserID: id(a.UserID)})
		if err == nil && !prior.RevokedAt.Valid {
			return nil, ErrState
		}
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		var random [10]byte
		if _, err = rand.Read(random[:]); err != nil {
			return nil, err
		}
		code := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(random[:])
		expires := c.now.Add(time.Duration(s.config.CheckinTTLSeconds) * time.Second)
		if c.e.EndsAt.Before(expires) {
			expires = *c.e.EndsAt
		}
		cid := newID()
		if err = q.SaveCheckinCredential(ctx, dbgen.SaveCheckinCredentialParams{ID: cid, ExperienceID: id(eid), UserID: id(a.UserID), SessionID: id(a.ID), CodeHash: s.codeHash(eid, code), ExpiresAt: ts(expires)}); err != nil {
			return nil, err
		}
		// No plaintext code or hash is copied into an event, receipt or audit record.
		if err = q.InsertParticipationAudit(ctx, dbgen.InsertParticipationAuditParams{ID: newID(), ExperienceID: id(eid), ActorUserID: id(a.UserID), SubjectUserID: id(a.UserID), Action: "checkin.credential_issued", ResourceVersion: m.Version, RequestID: requestID(ctx), Details: []byte(`{}`)}); err != nil {
			return nil, err
		}
		return Credential{code, expires, c.now}, nil
	})
}
func checkin(ctx context.Context, q *dbgen.Queries, ci dbgen.ParticipationCheckin) (Checkin, error) {
	out := Checkin{ID: str(ci.ID), ExperienceID: str(ci.ExperienceID), UserID: str(ci.UserID), CheckedAt: ci.CheckedAt.Time, Version: ci.Version}
	if ci.RevokedAt.Valid {
		t := ci.RevokedAt.Time
		out.RevokedAt = &t
	}
	person, err := q.ParticipationPublicPerson(ctx, ci.UserID)
	if err != nil {
		return out, err
	}
	out.DisplayName = person.DisplayName
	if person.Handle != "" {
		h := person.Handle
		out.Handle = &h
	}
	return out, nil
}
func (s *Service) ValidateCheckin(ctx context.Context, a *identity.Session, eid, key, code, request string) (json.RawMessage, error) {
	code = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(code), "-", ""))
	if !codePattern.MatchString(code) {
		return nil, ErrCode
	}
	return s.run(ctx, a, eid, key, "checkin.validate", request, code, true, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if !c.owner(a.UserID) {
			return nil, identity.ErrNotFound
		}
		if !s.checkinWindow(c) {
			return nil, ErrCheckin
		}
		credential, err := q.GetCheckinCredential(ctx, dbgen.GetCheckinCredentialParams{ExperienceID: id(eid), CodeHash: s.codeHash(eid, code)})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrCode
		}
		if err != nil {
			return nil, err
		}
		if credential.UsedAt.Valid {
			return nil, ErrReplay
		}
		if !credential.ExpiresAt.Time.After(c.now) {
			return nil, ErrCodeExpired
		}
		user := str(credential.UserID)
		active, err := q.ParticipationTargetActive(ctx, credential.UserID)
		if err != nil {
			return nil, err
		}
		sessionActive, err := q.ParticipationCredentialSessionActive(ctx, credential.SessionID)
		if err != nil {
			return nil, err
		}
		m, err := member(ctx, q, eid, user)
		if err != nil {
			return nil, err
		}
		if !active || !sessionActive || m.State != "CONFIRMED" || m.Blocked {
			return nil, ErrCheckin
		}
		prior, err := q.GetParticipationCheckin(ctx, dbgen.GetParticipationCheckinParams{ExperienceID: id(eid), UserID: credential.UserID})
		if err == nil && !prior.RevokedAt.Valid {
			return nil, ErrReplay
		}
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		ci, err := q.SaveParticipationCheckin(ctx, dbgen.SaveParticipationCheckinParams{ID: newID(), ExperienceID: id(eid), UserID: credential.UserID, CheckedBy: id(a.UserID)})
		if err != nil {
			return nil, err
		}
		if err = q.ConsumeCheckinCredential(ctx, credential.ID); err != nil {
			return nil, err
		}
		if err = emit(ctx, q, eid, a.UserID, user, "checkin.completed", ci.Version, str(ci.ID), "CHECKED_IN", map[string]any{}); err != nil {
			return nil, err
		}
		return checkin(ctx, q, ci)
	})
}
func (s *Service) RevokeCheckin(ctx context.Context, a *identity.Session, eid, user, key, request string) (json.RawMessage, error) {
	if !id(user).Valid {
		return nil, ErrInvalid
	}
	return s.run(ctx, a, eid, key, "checkin.revoke", request, user, true, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if !c.owner(a.UserID) {
			return nil, identity.ErrNotFound
		}
		if err := s.revokePresence(ctx, q, c, a.UserID, user); err != nil {
			return nil, err
		}
		ci, err := q.GetParticipationCheckin(ctx, dbgen.GetParticipationCheckinParams{ExperienceID: id(eid), UserID: id(user)})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, identity.ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		return checkin(ctx, q, ci)
	})
}
