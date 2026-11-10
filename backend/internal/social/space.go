package social

import (
	"context"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"strings"
	"time"
)

var ErrReadOnly = &identity.Failure{Code: "space_read_only", Status: 409}

func spaceGuard(a *identity.Session, eid string, write bool) func(context.Context, pgx.Tx, *dbgen.Queries) error {
	return func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries) error {
		if _, e := q.LockExperience(ctx, id(eid)); e != nil {
			return identity.ErrNotFound
		}
		ok, e := q.SpaceRead(ctx, dbgen.SpaceReadParams{Column1: id(eid), Column2: id(a.UserID)})
		if e != nil {
			return e
		}
		if !ok {
			return identity.ErrNotFound
		}
		if write {
			ok, e = q.SpaceWrite(ctx, dbgen.SpaceWriteParams{Column1: id(eid), Column2: id(a.UserID)})
			if e != nil {
				return e
			}
			if !ok {
				return ErrReadOnly
			}
		}
		return nil
	}
}

// Identity -> Experience -> post -> comment/media. This is also Participation's
// serialization point, so revocation and contextual writes cannot overtake it.
func postSpaceGuard(a *identity.Session, pid string, write bool) func(context.Context, pgx.Tx, *dbgen.Queries) error {
	return func(ctx context.Context, tx pgx.Tx, q *dbgen.Queries) error {
		p, e := q.SocialPostScope(ctx, id(pid))
		if e != nil {
			return identity.ErrNotFound
		}
		if p.Context != "EVENT_SPACE" {
			return nil
		}
		if !write {
			_, e = q.LockExperience(ctx, p.ExperienceID)
			return e
		}
		return spaceGuard(a, str(p.ExperienceID), true)(ctx, tx, q)
	}
}
func (s *Service) SpaceSummary(ctx context.Context, a *identity.Session, eid, req string) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if a == nil {
		return nil, identity.ErrUnauthorized
	}
	if !id(eid).Valid {
		return nil, identity.ErrInvalid
	}
	q := dbgen.New(s.pool)
	d, e := document(q.SpaceSummary(ctx, dbgen.SpaceSummaryParams{Viewer: id(a.UserID), ExperienceID: id(eid)}))
	if e != nil {
		return nil, e
	}
	caps := d["capabilities"].(map[string]any)
	if caps["can_read"] == true {
		if e = spaceReadAudit(ctx, q, a, eid, "eventspace.summary.read", req); e != nil {
			return nil, e
		}
	}
	return d, nil
}
func spaceReadAudit(ctx context.Context, q *dbgen.Queries, a *identity.Session, eid, action, req string) error {
	return q.SocialAudit(ctx, dbgen.SocialAuditParams{ID: newID(), Actor: a.UserID, ResourceID: id(eid), Action: action, RequestID: req, Details: []byte(`{}`)})
}

type SpaceModeration struct {
	TargetType string `json:"target_type"`
	TargetID   string `json:"target_id"`
	Action     string `json:"action"`
	Reason     string `json:"reason"`
}

func (s *Service) SpaceModeration(ctx context.Context, a *identity.Session, eid, key string, in SpaceModeration, req string) (map[string]any, error) {
	if !id(eid).Valid || !id(in.TargetID).Valid {
		return nil, identity.ErrInvalid
	}
	switch in.Reason {
	case "ABUSE", "SPAM", "PRIVACY", "SAFETY", "OTHER":
	default:
		return nil, identity.ErrInvalid
	}
	guard := func(ctx context.Context, tx pgx.Tx, q *dbgen.Queries) error {
		if e := spaceGuard(a, eid, false)(ctx, tx, q); e != nil {
			return e
		}
		ok, e := q.SpaceModerate(ctx, dbgen.SpaceModerateParams{Column1: id(eid), Column2: id(a.UserID)})
		if e != nil {
			return e
		}
		if !ok {
			return identity.ErrNotFound
		}
		return nil
	}
	return s.runGuarded(ctx, a, key, "space.moderation", req, []any{eid, in}, guard, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries) (string, error) {
		d, e := document(q.SpaceSummary(ctx, dbgen.SpaceSummaryParams{Viewer: id(a.UserID), ExperienceID: id(eid)}))
		if e != nil {
			return "", e
		}
		owner := d["role"] == "CREATOR"
		switch in.TargetType {
		case "POST", "COMMENT":
			if in.Action != "HIDE" && in.Action != "RESTORE" {
				return "", identity.ErrInvalid
			}
			pid := in.TargetID
			if in.TargetType == "COMMENT" {
				postID, e := q.SocialCommentPost(ctx, id(in.TargetID))
				if e != nil {
					return "", identity.ErrNotFound
				}
				pid = str(postID)
			}
			p, e := q.SocialLockPost(ctx, id(pid))
			if e != nil || p.ExperienceID != id(eid) || p.Context != "EVENT_SPACE" || p.DeletedAt.Valid {
				return "", identity.ErrNotFound
			}
			if in.TargetType == "POST" {
				e = q.SpaceSetPostHidden(ctx, dbgen.SpaceSetPostHiddenParams{ID: p.ID, LocalHidden: in.Action == "HIDE"})
			} else {
				c, x := q.SocialLockComment(ctx, id(in.TargetID))
				if x != nil || c.DeletedAt.Valid {
					return "", identity.ErrNotFound
				}
				e = q.SpaceSetCommentHidden(ctx, dbgen.SpaceSetCommentHiddenParams{ID: id(in.TargetID), LocalHidden: in.Action == "HIDE"})
			}
			if e != nil {
				return "", e
			}
		case "PARTICIPANT", "MODERATOR":
			if in.TargetID == a.UserID {
				return "", identity.ErrInvalid
			}
			m, e := q.SpaceMember(ctx, dbgen.SpaceMemberParams{ExperienceID: id(eid), UserID: id(in.TargetID)})
			if e != nil {
				return "", identity.ErrNotFound
			}
			if in.TargetType == "MODERATOR" {
				if !owner {
					return "", identity.ErrNotFound
				}
				if in.Action != "GRANT" && in.Action != "REVOKE" {
					return "", identity.ErrInvalid
				}
				if in.Action == "GRANT" {
					ok, e := q.SpaceRead(ctx, dbgen.SpaceReadParams{Column1: id(eid), Column2: id(in.TargetID)})
					if e != nil {
						return "", e
					}
					if !ok || m.Restricted {
						return "", identity.ErrNotFound
					}
				}
				e = q.SpaceSetModerator(ctx, dbgen.SpaceSetModeratorParams{ExperienceID: id(eid), UserID: id(in.TargetID), Active: in.Action == "GRANT"})
			} else {
				if in.Action != "RESTRICT" && in.Action != "ALLOW" {
					return "", identity.ErrInvalid
				}
				if m.State != "CONFIRMED" || m.Blocked || (!owner && m.Moderator) {
					return "", identity.ErrNotFound
				}
				e = q.SpaceSetRestriction(ctx, dbgen.SpaceSetRestrictionParams{ExperienceID: id(eid), UserID: id(in.TargetID), Restricted: in.Action == "RESTRICT"})
				if e == nil && in.Action == "RESTRICT" {
					e = q.SpaceSetModerator(ctx, dbgen.SpaceSetModeratorParams{ExperienceID: id(eid), UserID: id(in.TargetID), Active: false})
				}
			}
			if e != nil {
				return "", e
			}
		case "SPACE":
			if !owner || in.TargetID != eid {
				return "", identity.ErrNotFound
			}
			if in.Action != "PAUSE" && in.Action != "RESUME" {
				return "", identity.ErrInvalid
			}
			if e = q.SpaceSetPaused(ctx, dbgen.SpaceSetPausedParams{ExperienceID: id(eid), Paused: in.Action == "PAUSE"}); e != nil {
				return "", e
			}
		case "REPORT":
			if in.Action != "REVIEW" {
				return "", identity.ErrInvalid
			}
			r, e := q.SpaceReportTarget(ctx, id(in.TargetID))
			if e != nil || r.ExperienceID != id(eid) {
				return "", identity.ErrNotFound
			}
			if e = q.SpaceReviewReport(ctx, dbgen.SpaceReviewReportParams{ReportID: r.ID, ExperienceID: id(eid), ReviewedBy: id(a.UserID)}); e != nil {
				return "", e
			}
		default:
			return "", identity.ErrInvalid
		}
		return in.TargetID, emit(ctx, q, a.UserID, eid, "eventspace.moderation."+strings.ToLower(in.Action), req, map[string]any{"target_id": in.TargetID, "target_type": in.TargetType, "reason": in.Reason})
	})
}

func (s *Service) SpaceList(ctx context.Context, a *identity.Session, eid, section, cursor string, limit int, req string) (Page, error) {
	out, e := s.List(ctx, a, "SPACE_"+section, eid, cursor, limit)
	if e != nil {
		return out, e
	}
	if section == "PARTICIPANTS" || section == "REPORTS" || section == "HIDDEN" {
		e = spaceReadAudit(ctx, dbgen.New(s.pool), a, eid, "eventspace."+strings.ToLower(section)+".read", req)
	}
	return out, e
}

// Reports remain available in read-only memories but cannot race a membership
// revocation or replay a receipt after the contextual authorization was lost.
func reportSpaceGuard(a *identity.Session, in Report) func(context.Context, pgx.Tx, *dbgen.Queries) error {
	return func(ctx context.Context, tx pgx.Tx, q *dbgen.Queries) error {
		pid := in.TargetID
		if in.TargetType == "CHAT_MESSAGE" {
			eid, e := q.ChatMessageSpace(ctx, id(in.TargetID))
			if e != nil {
				return identity.ErrNotFound
			}
			return spaceGuard(a, str(eid), false)(ctx, tx, q)
		}
		if in.TargetType == "USER" {
			return nil
		}
		if in.TargetType == "COMMENT" {
			p, e := q.SocialCommentPost(ctx, id(in.TargetID))
			if e != nil {
				return identity.ErrNotFound
			}
			pid = str(p)
		}
		scope, e := q.SocialPostScope(ctx, id(pid))
		if e != nil {
			return identity.ErrNotFound
		}
		if scope.Context != "EVENT_SPACE" {
			return nil
		}
		return spaceGuard(a, str(scope.ExperienceID), false)(ctx, tx, q)
	}
}
