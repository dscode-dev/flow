package participation

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

func (s *Service) Interest(ctx context.Context, a *identity.Session, eid, key string, enabled bool, request string) (json.RawMessage, error) {
	return s.run(ctx, a, eid, key, "interest", request, enabled, true, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if c.owner(a.UserID) || (!c.open() && enabled) {
			return nil, ErrState
		}
		m, err := member(ctx, q, eid, a.UserID)
		if err != nil {
			return nil, err
		}
		if m.Interested != enabled {
			m.Interested = enabled
			m, err = saveMember(ctx, q, m)
			if err != nil {
				return nil, err
			}
			action := "participation.interest_removed"
			if enabled {
				action = "participation.interested"
			}
			if err = emit(ctx, q, eid, a.UserID, a.UserID, action, m.Version, str(m.ID), m.State, map[string]any{"interested": enabled}); err != nil {
				return nil, err
			}
		}
		return summary(ctx, q, c, a.UserID, s.config)
	})
}
func (s *Service) Participate(ctx context.Context, a *identity.Session, eid, key, action, request string) (json.RawMessage, error) {
	if action != "confirm" && action != "request" && action != "cancel" {
		return nil, ErrInvalid
	}
	return s.run(ctx, a, eid, key, "participation."+action, request, nil, true, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if c.owner(a.UserID) {
			return nil, ErrState
		}
		m, err := member(ctx, q, eid, a.UserID)
		if err != nil {
			return nil, err
		}
		target, event := "", ""
		switch action {
		case "cancel":
			if m.State == "CANCELLED" || m.State == "NONE" {
				return summary(ctx, q, c, a.UserID, s.config)
			}
			if m.State != "PENDING" && m.State != "CONFIRMED" {
				return nil, ErrState
			}
			target, event = "CANCELLED", "participation.cancelled"
		case "confirm":
			if !c.open() || c.mode != "FREE" || c.e.Visibility == "PRIVATE" {
				return nil, ErrState
			}
			if m.State == "CONFIRMED" {
				return summary(ctx, q, c, a.UserID, s.config)
			}
			if m.State != "NONE" && m.State != "CANCELLED" {
				return nil, ErrState
			}
			target, event = "CONFIRMED", "participation.confirmed"
		case "request":
			if !c.open() || c.mode != "APPROVAL" || c.e.Visibility == "PRIVATE" {
				return nil, ErrState
			}
			if m.State == "PENDING" {
				return summary(ctx, q, c, a.UserID, s.config)
			}
			if m.State != "NONE" && m.State != "CANCELLED" {
				return nil, ErrState
			}
			target, event = "PENDING", "participation.requested"
		}
		if target == "CONFIRMED" && c.e.Capacity != nil && c.count >= int64(*c.e.Capacity) {
			return nil, ErrFull
		}
		m.State = target
		m, err = saveMember(ctx, q, m)
		if err != nil {
			return nil, err
		}
		if action == "cancel" {
			if err = s.revokePresence(ctx, q, c, a.UserID, a.UserID); err != nil {
				return nil, err
			}
		}
		if err = emit(ctx, q, eid, a.UserID, a.UserID, event, m.Version, str(m.ID), m.State, map[string]any{"interested": m.Interested}); err != nil {
			return nil, err
		}
		c, err = contextFor(ctx, q, eid, a.UserID)
		if err != nil {
			return nil, err
		}
		return summary(ctx, q, c, a.UserID, s.config)
	})
}
func (s *Service) revokePresence(ctx context.Context, q *dbgen.Queries, c state, actor, user string) error {
	if err := q.RevokeCheckinCredential(ctx, dbgen.RevokeCheckinCredentialParams{ExperienceID: id(c.e.ID), UserID: id(user)}); err != nil {
		return err
	}
	ci, err := q.RevokeParticipationCheckin(ctx, dbgen.RevokeParticipationCheckinParams{ExperienceID: id(c.e.ID), UserID: id(user), RevokedBy: id(actor)})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	return emit(ctx, q, c.e.ID, actor, user, "checkin.revoked", ci.Version, str(ci.ID), "REVOKED", map[string]any{})
}
func (s *Service) Manage(ctx context.Context, a *identity.Session, eid, user, key, action, request string, reasons ...string) (json.RawMessage, error) {
	reason := ""
	if len(reasons) > 0 {
		reason = reasons[0]
	}
	switch reason {
	case "", "ABUSE", "SPAM", "PRIVACY", "SAFETY", "OTHER":
	default:
		return nil, ErrInvalid
	}
	var intent any = user
	if reason != "" {
		intent = []string{user, reason}
	}
	if !id(user).Valid {
		return nil, ErrInvalid
	}
	switch action {
	case "approve", "decline", "remove", "block", "unblock":
	default:
		return nil, ErrInvalid
	}
	return s.run(ctx, a, eid, key, "member."+action, request, intent, true, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries, c state) (any, error) {
		if !c.owner(a.UserID) || user == a.UserID {
			return nil, identity.ErrNotFound
		}
		if !c.open() && !(c.e.PublishedAt != nil && (action == "remove" || action == "block" || action == "unblock")) {
			return nil, ErrState
		}
		m, err := member(ctx, q, eid, user)
		if err != nil {
			return nil, err
		}
		if m.Version == 0 && action != "block" {
			return nil, identity.ErrNotFound
		}
		event, target := "", m.State
		switch action {
		case "approve":
			active, err := q.ParticipationTargetActive(ctx, id(user))
			if err != nil {
				return nil, err
			}
			if !active || m.Blocked {
				return nil, ErrState
			}
			if m.State == "CONFIRMED" {
				return memberResult(ctx, q, m)
			}
			if m.State != "PENDING" {
				return nil, ErrState
			}
			if c.e.Capacity != nil && c.count >= int64(*c.e.Capacity) {
				return nil, ErrFull
			}
			target, event = "CONFIRMED", "participation.confirmed"
		case "decline":
			if m.State == "DECLINED" {
				return memberResult(ctx, q, m)
			}
			if m.State != "PENDING" {
				return nil, ErrState
			}
			target, event = "DECLINED", "participation.declined"
		case "remove":
			if m.State == "REMOVED" {
				return memberResult(ctx, q, m)
			}
			if m.State != "PENDING" && m.State != "CONFIRMED" {
				return nil, ErrState
			}
			target, event = "REMOVED", "participation.removed"
		case "block":
			active, err := q.ParticipationTargetActive(ctx, id(user))
			if err != nil {
				return nil, err
			}
			if !active && m.Version == 0 {
				return nil, identity.ErrNotFound
			}
			if m.Blocked {
				return memberResult(ctx, q, m)
			}
			m.Blocked = true
			m.Interested = false
			target, event = "REMOVED", "participation.blocked"
		case "unblock":
			if !m.Blocked {
				return memberResult(ctx, q, m)
			}
			m.Blocked = false
			event = "participation.unblocked"
		}
		m.State = target
		m, err = saveMember(ctx, q, m)
		if err != nil {
			return nil, err
		}
		if action == "remove" || action == "block" || action == "decline" {
			if err = s.revokePresence(ctx, q, c, a.UserID, user); err != nil {
				return nil, err
			}
			i, err := q.GetParticipationInvitation(ctx, dbgen.GetParticipationInvitationParams{ExperienceID: id(eid), InviteeUserID: id(user)})
			if err == nil && (i.State == "PENDING" || i.State == "ACCEPTED") {
				i, err = q.UpdateParticipationInvitation(ctx, dbgen.UpdateParticipationInvitationParams{ID: i.ID, State: "REVOKED"})
				if err != nil {
					return nil, err
				}
				if err = emit(ctx, q, eid, a.UserID, user, "invitation.revoked", i.Version, str(i.ID), i.State, map[string]any{}); err != nil {
					return nil, err
				}
			} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return nil, err
			}
		}
		if err = emit(ctx, q, eid, a.UserID, user, event, m.Version, str(m.ID), m.State, map[string]any{"blocked": m.Blocked, "reason": reason}); err != nil {
			return nil, err
		}
		return memberResult(ctx, q, m)
	})
}
func memberResult(ctx context.Context, q *dbgen.Queries, m dbgen.ParticipationMember) (any, error) {
	ci, err := q.GetParticipationCheckin(ctx, dbgen.GetParticipationCheckinParams{ExperienceID: m.ExperienceID, UserID: m.UserID})
	var checkedAt *time.Time
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	checked := err == nil && !ci.RevokedAt.Valid && m.State == "CONFIRMED"
	if checked {
		t := ci.CheckedAt.Time
		checkedAt = &t
	}
	return Member{UserID: str(m.UserID), State: m.State, Interested: m.Interested, Blocked: m.Blocked, Version: m.Version, UpdatedAt: m.UpdatedAt.Time, CheckedIn: checked, CheckedAt: checkedAt}, nil
}
