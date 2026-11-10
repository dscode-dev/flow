package social

import (
	"context"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
)

func (s *Service) Relation(ctx context.Context, a *identity.Session, uid, key, action, req string) (map[string]any, error) {
	if !id(uid).Valid || a == nil {
		return nil, identity.ErrInvalid
	}
	if uid == a.UserID {
		return nil, identity.ErrInvalid
	}
	return s.run(ctx, a, key, "relation."+action, req, uid, func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries) (string, error) {
		if e := q.SocialPairLock(ctx, dbgen.SocialPairLockParams{Column1: a.UserID, Column2: uid}); e != nil {
			return "", e
		}
		var n int64
		var e error
		switch action {
		case "follow":
			if e = connected(ctx, q, a.UserID, uid); e != nil {
				return "", e
			}
			n, e = q.SocialFollow(ctx, dbgen.SocialFollowParams{FollowerID: id(a.UserID), FollowedID: id(uid)})
		case "unfollow":
			n, e = q.SocialUnfollow(ctx, dbgen.SocialUnfollowParams{FollowerID: id(a.UserID), FollowedID: id(uid)})
		case "block":
			active, x := q.SocialActive(ctx, id(uid))
			if x != nil {
				return "", x
			}
			if !active {
				return "", identity.ErrNotFound
			}
			n, e = q.SocialBlock(ctx, dbgen.SocialBlockParams{BlockerID: id(a.UserID), BlockedID: id(uid)})
			if e == nil {
				e = q.SocialSeverFollows(ctx, dbgen.SocialSeverFollowsParams{FollowerID: id(a.UserID), FollowedID: id(uid)})
			}
		case "unblock":
			n, e = q.SocialUnblock(ctx, dbgen.SocialUnblockParams{BlockerID: id(a.UserID), BlockedID: id(uid)})
		default:
			return "", identity.ErrInvalid
		}
		if e != nil {
			return "", e
		}
		if n == 0 {
			return uid, nil
		}
		events := map[string]string{"follow": "social.follow.created", "unfollow": "social.follow.removed", "block": "social.user.blocked", "unblock": "social.user.unblocked"}
		return uid, emit(ctx, q, a.UserID, uid, events[action], req, map[string]any{})
	})
}
func (s *Service) DeleteComment(ctx context.Context, a *identity.Session, pid, cid, key, req string) (map[string]any, error) {
	if !id(pid).Valid || !id(cid).Valid {
		return nil, identity.ErrInvalid
	}
	return s.runGuarded(ctx, a, key, "comment.delete", req, []string{pid, cid}, postSpaceGuard(a, pid, false), func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries) (string, error) {
		// Parent first, matching post deletion/moderation and comment creation.
		p, e := q.SocialLockPost(ctx, id(pid))
		if e != nil {
			return "", identity.ErrNotFound
		}
		c, e := q.SocialLockComment(ctx, id(cid))
		if e != nil || c.PostID != p.ID || (c.AuthorUserID != id(a.UserID) && p.AuthorUserID != id(a.UserID)) {
			return "", identity.ErrNotFound
		}
		if !(p.Context == "EVENT_SPACE" && c.AuthorUserID == id(a.UserID)) {
			if _, e = loadPost(ctx, q, pid, a.UserID); e != nil {
				return "", e
			}
		}
		if e = connected(ctx, q, a.UserID, str(c.AuthorUserID)); e != nil {
			return "", e
		}
		if c.DeletedAt.Valid {
			return cid, nil
		}
		if c.ModerationStatus != "VISIBLE" {
			return "", identity.ErrNotFound
		}
		if e = q.SocialDeleteComment(ctx, c.ID); e != nil {
			return "", e
		}
		return cid, emit(ctx, q, a.UserID, cid, "social.comment.deleted", req, map[string]any{"post_id": pid})
	})
}
func (s *Service) Report(ctx context.Context, a *identity.Session, key string, in Report, req string) (map[string]any, error) {
	if !id(in.TargetID).Valid {
		return nil, identity.ErrInvalid
	}
	switch in.Reason {
	case "ABUSE", "SPAM", "PRIVACY", "ILLEGAL", "OTHER":
	default:
		return nil, identity.ErrInvalid
	}
	return s.runGuarded(ctx, a, key, "report", req, in, reportSpaceGuard(a, in), func(ctx context.Context, _ pgx.Tx, q *dbgen.Queries) (string, error) {
		switch in.TargetType {
		case "USER":
			if e := connected(ctx, q, a.UserID, in.TargetID); e != nil {
				own, x := q.SocialOwnBlock(ctx, dbgen.SocialOwnBlockParams{BlockerID: id(a.UserID), BlockedID: id(in.TargetID)})
				if x != nil {
					return "", x
				}
				if !own {
					return "", identity.ErrNotFound
				}
			}
			if in.TargetID == a.UserID {
				return "", identity.ErrInvalid
			}
		case "POST":
			if _, e := loadPost(ctx, q, in.TargetID, a.UserID); e != nil {
				return "", e
			}
		case "CHAT_MESSAGE":
			m, e := q.ChatLockMessage(ctx, id(in.TargetID))
			if e != nil || m.DeletedAt.Valid || m.ModerationStatus != "VISIBLE" {
				return "", identity.ErrNotFound
			}
			raw, e := q.ChatDocument(ctx, dbgen.ChatDocumentParams{Column1: m.ID, Column2: id(a.UserID)})
			if e != nil {
				return "", e
			}
			d, e := document(raw, nil)
			if e != nil || d["removed"] == true {
				return "", identity.ErrNotFound
			}
		case "COMMENT":
			c, e := q.SocialLockComment(ctx, id(in.TargetID))
			if e != nil || c.DeletedAt.Valid || c.LocalHidden || c.ModerationStatus != "VISIBLE" {
				return "", identity.ErrNotFound
			}
			if _, e = loadPost(ctx, q, str(c.PostID), a.UserID); e != nil {
				return "", e
			}
			visible, e := q.SocialInteractionVisible(ctx, dbgen.SocialInteractionVisibleParams{Column1: c.PostID, Column2: c.AuthorUserID, Column3: id(a.UserID)})
			if e != nil {
				return "", e
			}
			if !visible {
				return "", identity.ErrNotFound
			}
		default:
			return "", identity.ErrInvalid
		}
		rid := newID()
		n, e := q.SocialReport(ctx, dbgen.SocialReportParams{ID: rid, ReporterUserID: id(a.UserID), TargetType: in.TargetType, TargetID: id(in.TargetID), Reason: in.Reason})
		if e != nil {
			return "", e
		}
		if n == 0 {
			return in.TargetID, nil
		}
		return in.TargetID, emit(ctx, q, a.UserID, in.TargetID, "social.content.reported", req, map[string]any{"report_id": str(rid), "target_type": in.TargetType, "reason": in.Reason})
	})
}
