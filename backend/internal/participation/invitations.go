package participation

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

var handlePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{2,29}$`)

func (s *Service) Invite(ctx context.Context, a *identity.Session, eid, key string, in InvitationInput, request string) (json.RawMessage, error) {
	in.Handle = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(in.Handle), "@"))
	if (in.UserID == "") == (in.Handle == "") || in.UserID != "" && !id(in.UserID).Valid || in.Handle != "" && !handlePattern.MatchString(in.Handle) {
		return nil, ErrInvalid
	}
	hours := int32(72)
	if in.ExpiresHours != nil {
		hours = *in.ExpiresHours
	}
	if hours < 1 || hours > 168 {
		return nil, ErrInvalid
	}
	return s.run(ctx, a, eid, key, "invitation.create", request, in, true, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if !c.owner(a.UserID) {
			return nil, identity.ErrNotFound
		}
		if !c.open() {
			return nil, ErrState
		}
		uid, err := q.FindParticipationInvitee(ctx, dbgen.FindParticipationInviteeParams{UserID: id(in.UserID), Handle: in.Handle})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInvite
		}
		if err != nil {
			return nil, err
		}
		user := str(uid)
		if user == a.UserID {
			return nil, ErrInvite
		}
		m, err := member(ctx, q, eid, user)
		if err != nil {
			return nil, err
		}
		if m.Blocked || m.State == "CONFIRMED" {
			return nil, ErrInvite
		}
		prior, err := q.GetParticipationInvitation(ctx, dbgen.GetParticipationInvitationParams{ExperienceID: id(eid), InviteeUserID: uid})
		if err == nil && prior.State == "PENDING" && prior.ExpiresAt.Time.After(c.now) {
			return invitation(prior, c.now), nil
		}
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		expiry := c.now.Add(time.Duration(hours) * time.Hour)
		if c.e.EndsAt.Before(expiry) {
			expiry = *c.e.EndsAt
		}
		row, err := q.SaveParticipationInvitation(ctx, dbgen.SaveParticipationInvitationParams{ID: newID(), ExperienceID: id(eid), InviteeUserID: uid, SenderUserID: id(a.UserID), State: "PENDING", ExpiresAt: ts(expiry)})
		if err != nil {
			return nil, err
		}
		if err = emit(ctx, q, eid, a.UserID, user, "invitation.created", row.Version, str(row.ID), row.State, map[string]any{"expires_at": expiry}); err != nil {
			return nil, err
		}
		return invitation(row, c.now), nil
	})
}
func (s *Service) RespondInvitation(ctx context.Context, a *identity.Session, iid, key, action, request string) (json.RawMessage, error) {
	if a == nil {
		return nil, identity.ErrUnauthorized
	}
	if !id(iid).Valid {
		return nil, ErrInvalid
	}
	if action != "accept" && action != "decline" && action != "revoke" {
		return nil, ErrInvalid
	}
	i, err := dbgen.New(s.pool).FindParticipationInvitation(ctx, id(iid))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, identity.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	// Recipient identity is checked before any invitation metadata is returned.
	if action != "revoke" && str(i.InviteeUserID) != a.UserID {
		return nil, identity.ErrNotFound
	}
	eid, user := str(i.ExperienceID), str(i.InviteeUserID)
	return s.run(ctx, a, eid, key, "invitation."+action, request, iid, true, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if action == "revoke" && !c.owner(a.UserID) {
			return nil, identity.ErrNotFound
		}
		i, err := q.GetParticipationInvitation(ctx, dbgen.GetParticipationInvitationParams{ExperienceID: id(eid), InviteeUserID: id(user)})
		if err != nil {
			return nil, err
		}
		if str(i.ID) != iid {
			return nil, identity.ErrNotFound
		}
		target, event := "", ""
		switch action {
		case "accept":
			target, event = "ACCEPTED", "invitation.accepted"
		case "decline":
			target, event = "DECLINED", "invitation.declined"
		case "revoke":
			target, event = "REVOKED", "invitation.revoked"
		}
		if i.State == target {
			return invitation(i, c.now), nil
		}
		if action == "revoke" {
			if i.State != "PENDING" {
				return nil, ErrState
			} // Accepted attendance is revoked through remove/block, never by invite alone.
		} else {
			if !c.open() || i.State != "PENDING" {
				return nil, ErrState
			}
			if !i.ExpiresAt.Time.After(c.now) {
				return nil, ErrExpired
			}
		}
		if action == "accept" {
			m, err := member(ctx, q, eid, user)
			if err != nil {
				return nil, err
			}
			if m.Blocked {
				return nil, ErrState
			}
			if m.State != "CONFIRMED" {
				if c.e.Capacity != nil && c.count >= int64(*c.e.Capacity) {
					return nil, ErrFull
				}
				m.State = "CONFIRMED"
				m, err = saveMember(ctx, q, m)
				if err != nil {
					return nil, err
				}
				if err = emit(ctx, q, eid, a.UserID, user, "participation.confirmed", m.Version, str(m.ID), m.State, map[string]any{"invitation_id": iid}); err != nil {
					return nil, err
				}
			}
		}
		i, err = q.UpdateParticipationInvitation(ctx, dbgen.UpdateParticipationInvitationParams{ID: i.ID, State: target})
		if err != nil {
			return nil, err
		}
		if err = emit(ctx, q, eid, a.UserID, user, event, i.Version, str(i.ID), i.State, map[string]any{}); err != nil {
			return nil, err
		}
		return invitation(i, c.now), nil
	})
}
