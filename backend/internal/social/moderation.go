package social

import (
	"context"
	"encoding/json"
	"flow.local/backend/internal/identity"
	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"regexp"
	"strings"
)

// Operate is deliberately not registered in HTTP. The CLI requires a separate
// database credential and attributable operator/case. Every inspection is audited.
func Operate(ctx context.Context, p *pgxpool.Pool, operator, caseID, action, target string) ([]json.RawMessage, error) {
	pattern := regexp.MustCompile(`^[A-Za-z0-9_.:@-]{3,100}$`)
	if !pattern.MatchString(operator) || !pattern.MatchString(caseID) {
		return nil, identity.ErrInvalid
	}
	if action != "reports" && !id(target).Valid {
		return nil, identity.ErrInvalid
	}
	out := []json.RawMessage{}
	e := database.InTransaction(ctx, p, func(tx pgx.Tx) error {
		q := dbgen.New(tx)
		var err error
		switch action {
		case "posts", "post":
			pid, author := id(""), id("")
			if action == "post" {
				pid = id(target)
			} else {
				author = id(target)
			}
			rows, e := q.SocialOperationalPosts(ctx, dbgen.SocialOperationalPostsParams{PostID: pid, Author: author})
			if e != nil {
				return e
			}
			for _, b := range rows {
				out = append(out, json.RawMessage(b))
			}
		case "reports":
			rows, e := q.SocialOperationalReports(ctx)
			if e != nil {
				return e
			}
			for _, b := range rows {
				out = append(out, json.RawMessage(b))
			}
		case "hide-post", "show-post", "delete-post":
			p, e := q.SocialLockPost(ctx, id(target))
			if e != nil {
				return identity.ErrNotFound
			}
			if action == "delete-post" {
				err = q.SocialDeletePost(ctx, p.ID)
			} else {
				state := "WITHHELD"
				if action == "show-post" {
					state = "VISIBLE"
				}
				err = q.SocialModeratePost(ctx, dbgen.SocialModeratePostParams{ID: p.ID, ModerationStatus: state})
			}
		case "hide-comment", "show-comment":
			c, e := q.SocialLockComment(ctx, id(target))
			if e != nil {
				return identity.ErrNotFound
			}
			state := "WITHHELD"
			if action == "show-comment" {
				state = "VISIBLE"
			}
			err = q.SocialModerateComment(ctx, dbgen.SocialModerateCommentParams{ID: c.ID, ModerationStatus: state})
		case "restrict-user", "restore-user":
			if _, e := q.LockIdentityUser(ctx, id(target)); e != nil {
				return identity.ErrNotFound
			}
			err = q.SocialRestrict(ctx, dbgen.SocialRestrictParams{UserID: id(target), Restricted: action == "restrict-user"})
		case "resolve-report":
			_, err = q.SocialResolveReport(ctx, id(target))
		default:
			return identity.ErrInvalid
		}
		if err != nil {
			return err
		}
		resource := target
		if !id(resource).Valid {
			resource = "00000000-0000-0000-0000-000000000000"
		}
		return emit(ctx, q, "operator:"+operator, resource, "social.moderation."+strings.ReplaceAll(action, "-", "_"), caseID, map[string]any{"case_id": caseID})
	})
	return out, e
}
