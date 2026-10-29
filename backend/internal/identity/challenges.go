package identity

import (
	"context"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"regexp"
	"strings"
	"time"

	"flow.local/backend/internal/identity/provider"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"github.com/nyaruka/phonenumbers"
)

type ChallengeRequest struct {
	Provider string `json:"provider"`
	Phone    string `json:"phone"`
	Purpose  string `json:"purpose"`
}
type Challenge struct {
	ID          string    `json:"challenge_id"`
	ExpiresAt   time.Time `json:"expires_at"`
	ResendAfter int64     `json:"resend_after_seconds"`
	Nonce       string    `json:"nonce,omitempty"`
}

func (s *Service) normalizePhone(raw string) (string, error) {
	if len(raw) > 40 || !strings.HasPrefix(strings.TrimSpace(raw), "+") {
		return "", ErrInvalid
	}
	n, e := phonenumbers.Parse(raw, "")
	if e != nil || !phonenumbers.IsValidNumber(n) {
		return "", ErrInvalid
	}
	region := phonenumbers.GetRegionCodeForNumber(n)
	for _, r := range s.config.PhoneRegions {
		if region == r {
			return phonenumbers.Format(n, phonenumbers.E164), nil
		}
	}
	return "", ErrInvalid
}
func (s *Service) Challenge(ctx context.Context, r ChallengeRequest, session *Session, meta Metadata) (Challenge, error) {
	var out Challenge
	if r.Provider != "PHONE" && r.Provider != "GOOGLE" && r.Provider != "APPLE" {
		return out, ErrInvalid
	}
	if r.Purpose != "login" && r.Purpose != "link" && r.Purpose != "reauth" {
		return out, ErrInvalid
	}
	if r.Purpose != "login" && session == nil {
		return out, ErrUnauthorized
	}
	if r.Provider == "PHONE" && s.sms == nil {
		return out, ErrUnavailable
	}
	if r.Provider != "PHONE" && s.tokens[r.Provider] == nil {
		return out, ErrUnavailable
	}
	phone, subject, nonce := "", "", ""
	if r.Provider == "PHONE" {
		var e error
		phone, e = s.normalizePhone(r.Phone)
		if e != nil {
			return out, e
		}
		subject = s.config.reference("phone", phone)
		if e = s.limit(ctx, []bucket{{"sms:number:" + subject, time.Hour, s.config.SMSNumberHour}, {"sms:origin:" + meta.Origin, time.Hour, s.config.SMSOriginHour}, {"sms:global:day", 24 * time.Hour, s.config.SMSGlobalDay}, {"sms:global:minute", time.Minute, s.config.SMSGlobalMinute}}); e != nil {
			return out, e
		}
	} else {
		nonce = secret()
		if r.Provider == "APPLE" {
			nonce = hex.EncodeToString(digest(nonce))
		}
	}
	out = Challenge{ID: newID(), ExpiresAt: time.Now().UTC().Add(s.config.ChallengeTTL), Nonce: nonce}
	if r.Provider == "PHONE" {
		out.ResendAfter = int64(s.config.ResendCooldown.Seconds())
	}
	e := s.transaction(ctx, func(q *dbgen.Queries) error {
		if subject != "" {
			if e := q.IdentityAdvisoryLock(ctx, "phone-challenge:"+subject); e != nil {
				return e
			}
			last, e := q.LastPhoneChallengeAt(ctx, text(subject))
			if e != nil {
				return e
			}
			if last.Valid && time.Since(last.Time) < s.config.ResendCooldown {
				return ErrRate
			}
			if e = q.SupersedePhoneChallenges(ctx, text(subject)); e != nil {
				return e
			}
		}
		if r.Purpose != "login" {
			recent := time.Duration(0)
			if r.Purpose == "link" {
				recent = s.config.RecentAuth
			}
			if e := lockSession(ctx, q, session, recent); e != nil {
				return e
			}
		}
		sessionID := ""
		if r.Purpose != "login" {
			sessionID = session.ID
		}
		state := "pending"
		var nh []byte
		if r.Provider == "PHONE" {
			state = "sending"
		} else {
			nh = digest(nonce)
		}
		return q.InsertIdentityChallenge(ctx, dbgen.InsertIdentityChallengeParams{ID: id(out.ID), Provider: r.Provider, Purpose: r.Purpose, SessionID: id(sessionID), SubjectRef: text(subject), NonceHash: nh, Status: state, ExpiresAt: ts(out.ExpiresAt), OriginRef: meta.Origin})
	})
	if e != nil {
		return Challenge{}, e
	}
	if r.Provider == "PHONE" {
		sid, sendErr := s.sms.Start(ctx, phone)
		state := "pending"
		if sendErr != nil {
			state = "failed"
		}
		// Persistir falha mesmo quando a chamada de envio consumiu o prazo da requisição.
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
		defer cancel()
		e = s.q.SetChallengeDelivery(cleanup, dbgen.SetChallengeDeliveryParams{ID: id(out.ID), ProviderReference: text(sid), Status: state})
		if e != nil {
			return Challenge{}, e
		}
		if sendErr != nil {
			if e = s.denied(cleanup, meta, "", "", "sms.delivery", "provider_failure"); e != nil {
				return Challenge{}, e
			}
			return Challenge{}, ErrUnavailable
		}
	}
	return out, nil
}

// consume mantém consumo, identidade, sessão e outbox na mesma transação.
// Falhas de verificação persistem tentativas/auditoria, sem confirmar efeito de domínio.
func (s *Service) consume(ctx context.Context, p Proof, purpose string, session *Session, meta Metadata, apply func(*dbgen.Queries, string) error) error {
	if p.Provider != "PHONE" && p.Provider != "GOOGLE" && p.Provider != "APPLE" {
		return ErrInvalid
	}
	if !validID(p.ChallengeID) || p.Credential == "" || len(p.Credential) > 16384 {
		return ErrInvalid
	}
	if p.Provider == "PHONE" {
		if s.sms == nil {
			return ErrUnavailable
		}
		if !regexp.MustCompile(`^[0-9]{4,10}$`).MatchString(p.Credential) {
			return ErrCredential
		}
	} else if s.tokens[p.Provider] == nil {
		return ErrUnavailable
	}
	var rejected error
	e := s.transaction(ctx, func(q *dbgen.Queries) error {
		c, e := q.LockIdentityChallenge(ctx, id(p.ChallengeID))
		if errors.Is(e, pgx.ErrNoRows) {
			rejected = ErrCredential
			return audit(ctx, q, "", "", "auth.verify", "denied", "unknown_challenge", meta)
		}
		if e != nil {
			return e
		}
		if c.Provider != p.Provider || c.Purpose != purpose || (purpose != "login" && (session == nil || uuidText(c.SessionID) != session.ID)) {
			rejected = ErrCredential
			return audit(ctx, q, "", "", "auth.verify", "denied", "challenge_binding", meta)
		}
		if purpose == "link" && c.Status == "consumed" {
			return lockSession(ctx, q, session, s.config.RecentAuth)
		}
		if c.Status != "pending" || !c.ExpiresAt.Time.After(time.Now()) || int(c.Attempts) >= s.config.OTPAttempts {
			rejected = ErrCredential
			return audit(ctx, q, "", "", "auth.verify", "denied", "challenge_unusable", meta)
		}
		if e = q.AttemptIdentityChallenge(ctx, dbgen.AttemptIdentityChallengeParams{ID: id(c.ID), Attempts: int32(s.config.OTPAttempts)}); e != nil {
			return e
		}
		subject := ""
		accepted := false
		var verifyErr error
		if p.Provider == "PHONE" {
			accepted, verifyErr = s.sms.Check(ctx, c.ProviderReference.String, p.Credential)
			subject = c.SubjectRef.String
		} else {
			var verified provider.Identity
			verified, verifyErr = s.tokens[p.Provider].Verify(ctx, p.Credential)
			if verifyErr == nil {
				accepted = subtle.ConstantTimeCompare(c.NonceHash, digest(verified.Nonce)) == 1
				subject = verified.Subject
			}
		}
		if verifyErr != nil || !accepted {
			rejected = ErrCredential
			if errors.Is(verifyErr, provider.ErrUnavailable) || errors.Is(verifyErr, provider.ErrLimited) {
				rejected = ErrUnavailable
			}
			return audit(ctx, q, "", "", "auth.verify", "denied", SafeFailure(rejected).Code, meta)
		}
		// Unicidade cross-request antes do lock de usuário, sempre na mesma ordem.
		if e = q.IdentityAdvisoryLock(ctx, "identity:"+p.Provider+":"+subject); e != nil {
			return e
		}
		if purpose != "login" {
			recent := time.Duration(0)
			if purpose == "link" {
				recent = s.config.RecentAuth
			}
			if e = lockSession(ctx, q, session, recent); e != nil {
				return e
			}
		}
		if e = apply(q, subject); e != nil {
			return e
		}
		return q.ConsumeIdentityChallenge(ctx, id(c.ID))
	})
	if e != nil {
		var denied *Failure
		if errors.As(e, &denied) {
			user, sid := "", ""
			if session != nil {
				user, sid = session.UserID, session.ID
			}
			if auditErr := s.denied(ctx, meta, user, sid, "auth.proof", denied.Code); auditErr != nil {
				return auditErr
			}
		}
		return e
	}
	return rejected
}
