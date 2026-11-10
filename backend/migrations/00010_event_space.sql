-- +goose Up
CREATE SCHEMA event_space;
-- Space identity is the existing Experience ID. No copied aggregate/lifecycle.
CREATE TABLE event_space.settings(experience_id uuid PRIMARY KEY REFERENCES experiences.experiences(id),paused boolean NOT NULL DEFAULT false,platform_suspended boolean NOT NULL DEFAULT false,version bigint NOT NULL DEFAULT 1,updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE event_space.moderators(experience_id uuid NOT NULL REFERENCES experiences.experiences(id),user_id uuid NOT NULL REFERENCES identity.users(id),active boolean NOT NULL DEFAULT true,updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(experience_id,user_id));
CREATE TABLE event_space.restrictions(experience_id uuid NOT NULL REFERENCES experiences.experiences(id),user_id uuid NOT NULL REFERENCES identity.users(id),restricted boolean NOT NULL DEFAULT true,updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(experience_id,user_id));
CREATE TABLE event_space.report_reviews(report_id uuid PRIMARY KEY REFERENCES social.reports(id) ON DELETE CASCADE,experience_id uuid NOT NULL REFERENCES experiences.experiences(id),reviewed_by uuid NOT NULL REFERENCES identity.users(id),reviewed_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE social.posts DROP CONSTRAINT posts_context_check;
ALTER TABLE social.posts DROP CONSTRAINT posts_visibility_check;
ALTER TABLE social.posts DROP CONSTRAINT posts_check;
ALTER TABLE social.posts ADD CONSTRAINT posts_context_check CHECK(context IN ('PERSONAL','EXPERIENCE_PUBLIC','EVENT_SPACE'));
ALTER TABLE social.posts ADD CONSTRAINT posts_visibility_check CHECK(visibility IN ('PUBLIC','FOLLOWERS','SPACE'));
ALTER TABLE social.posts ADD CONSTRAINT posts_check CHECK((context='PERSONAL' AND experience_id IS NULL AND visibility<>'SPACE') OR (context='EXPERIENCE_PUBLIC' AND experience_id IS NOT NULL AND visibility<>'SPACE') OR (context='EVENT_SPACE' AND experience_id IS NOT NULL AND visibility='SPACE'));
ALTER TABLE social.posts ADD COLUMN local_hidden boolean NOT NULL DEFAULT false;
ALTER TABLE social.comments ADD COLUMN local_hidden boolean NOT NULL DEFAULT false;
CREATE INDEX space_posts_page ON social.posts(experience_id,created_at DESC,id DESC) WHERE context='EVENT_SPACE' AND deleted_at IS NULL;
-- +goose StatementBegin
CREATE FUNCTION event_space.can_read(eid uuid,viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT FROM experiences.experiences e WHERE e.id=eid AND e.status IN ('PUBLISHED','CANCELLED','ARCHIVED') AND e.moderation_status='VISIBLE'
 AND social.connected(e.creator_user_id,viewer)
 AND NOT EXISTS(SELECT FROM event_space.settings s WHERE s.experience_id=e.id AND s.platform_suspended)
 AND NOT EXISTS(SELECT FROM experiences.publishing_restrictions r WHERE r.creator_user_id=e.creator_user_id AND r.blocked_until>now())
 AND (e.creator_user_id=viewer OR EXISTS(SELECT FROM participation.members m WHERE m.experience_id=e.id AND m.user_id=viewer AND m.state='CONFIRMED' AND NOT m.blocked)))
$$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE FUNCTION event_space.can_moderate(eid uuid,viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT event_space.can_read(eid,viewer) AND EXISTS(SELECT FROM experiences.experiences e WHERE e.id=eid AND (e.creator_user_id=viewer OR EXISTS(SELECT FROM event_space.moderators m WHERE m.experience_id=e.id AND m.user_id=viewer AND m.active)))
$$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE FUNCTION event_space.can_write(eid uuid,viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT event_space.can_read(eid,viewer) AND EXISTS(SELECT FROM experiences.experiences e WHERE e.id=eid AND e.status='PUBLISHED' AND e.ends_at>now()
 AND NOT EXISTS(SELECT FROM event_space.settings s WHERE s.experience_id=e.id AND s.paused)
 AND NOT EXISTS(SELECT FROM event_space.restrictions r WHERE r.experience_id=e.id AND r.user_id=viewer AND r.restricted))
$$;
-- +goose StatementEnd
-- A removed moderator must be explicitly appointed again after reconfirmation.
-- +goose StatementBegin
CREATE FUNCTION event_space.revoke_moderator() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.state<>'CONFIRMED' OR NEW.blocked THEN
  UPDATE event_space.moderators SET active=false,updated_at=now() WHERE experience_id=NEW.experience_id AND user_id=NEW.user_id AND active;
  IF FOUND THEN
   INSERT INTO social.audit(id,actor,resource_id,action,request_id,details) VALUES(gen_random_uuid(),'system:participation',NEW.experience_id,'eventspace.moderator.revoked','participation-trigger',jsonb_build_object('subject_user_id',NEW.user_id,'reason','PARTICIPATION_CHANGED'));
   INSERT INTO integration.outbox(event_id,event_type,schema_version,aggregate_id,occurred_at,payload) VALUES(gen_random_uuid(),'eventspace.moderator.revoked',1,NEW.experience_id,now(),jsonb_build_object('resource_id',NEW.experience_id));
  END IF;
 END IF;
 RETURN NEW;
END $$;
-- +goose StatementEnd
CREATE TRIGGER space_moderator_revoke AFTER UPDATE OF state,blocked ON participation.members FOR EACH ROW EXECUTE FUNCTION event_space.revoke_moderator();
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION social.can_read(pid uuid,viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT FROM social.posts p WHERE p.id=pid AND p.deleted_at IS NULL AND p.moderation_status='VISIBLE' AND NOT p.local_hidden
 AND social.connected(p.author_user_id,viewer)
 AND ((p.context='EVENT_SPACE' AND event_space.can_read(p.experience_id,viewer) AND event_space.can_read(p.experience_id,p.author_user_id)) OR
 (p.context<>'EVENT_SPACE' AND (p.visibility='PUBLIC' OR p.author_user_id=viewer OR EXISTS(SELECT FROM social.follows f WHERE f.follower_id=viewer AND f.followed_id=p.author_user_id))
 AND (p.context='PERSONAL' OR social.experience_eligible(p.experience_id,p.author_user_id,viewer)))))
$$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE FUNCTION social.interaction_visible(pid uuid,actor uuid,viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT social.connected(actor,viewer) AND EXISTS(SELECT FROM social.posts p WHERE p.id=pid AND social.connected(p.author_user_id,actor) AND (p.context<>'EVENT_SPACE' OR event_space.can_read(p.experience_id,actor)))
$$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION social.post_document(pid uuid,viewer uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT jsonb_build_object('id',p.id,'author',social.person(p.author_user_id),'context',p.context,'experience_id',p.experience_id,
 'experience_title',(SELECT e.title FROM experiences.experiences e WHERE e.id=p.experience_id),
 'visibility',p.visibility,'body',p.body,'created_at',p.created_at,'updated_at',p.updated_at,'edited_at',p.edited_at,'version',p.version,'can_manage',p.author_user_id=viewer,
 'can_interact',p.context<>'EVENT_SPACE' OR event_space.can_write(p.experience_id,viewer),
 'can_context_moderate',p.context='EVENT_SPACE' AND event_space.can_moderate(p.experience_id,viewer),
 'liked',EXISTS(SELECT FROM social.likes l WHERE l.post_id=p.id AND l.user_id=viewer),
 'like_count',(SELECT count(*) FROM social.likes l WHERE l.post_id=p.id AND social.interaction_visible(p.id,l.user_id,viewer)),
 'comment_count',(SELECT count(*) FROM social.comments c WHERE c.post_id=p.id AND c.deleted_at IS NULL AND c.moderation_status='VISIBLE' AND NOT c.local_hidden AND social.interaction_visible(p.id,c.author_user_id,viewer)),
 'media',coalesce((SELECT jsonb_agg(jsonb_build_object('id',a.id,'status',a.status,'content_type',CASE WHEN a.duration_ms IS NOT NULL THEN 'video/mp4' ELSE a.content_type END,'size_bytes',a.verified_size,'sha256',a.sha256,'width',a.width,'height',a.height,'duration_ms',a.duration_ms,'failure_code',a.failure_code,'variant','sanitized-v1') ORDER BY m.position) FROM social.post_media m JOIN media.flow_assets a ON a.id=m.asset_id WHERE m.post_id=p.id),'[]'::jsonb))
 FROM social.posts p WHERE p.id=pid AND social.can_read(p.id,viewer)
$$;
-- +goose StatementEnd

-- +goose Down
DROP INDEX social.space_posts_page;
DROP TRIGGER space_moderator_revoke ON participation.members;
-- Explicit rollback removes only records of the newly introduced context.
DELETE FROM social.posts WHERE context='EVENT_SPACE';
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION social.can_read(pid uuid,viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT FROM social.posts p WHERE p.id=pid AND p.deleted_at IS NULL AND p.moderation_status='VISIBLE'
 AND social.connected(p.author_user_id,viewer)
 AND (p.visibility='PUBLIC' OR p.author_user_id=viewer OR EXISTS(SELECT FROM social.follows f WHERE f.follower_id=viewer AND f.followed_id=p.author_user_id))
 AND (p.context='PERSONAL' OR social.experience_eligible(p.experience_id,p.author_user_id,viewer)))
$$;
-- +goose StatementEnd
-- No private identity fields or non-authorized engagement in documents.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION social.person(uid uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT jsonb_build_object('user_id',p.user_id,'display_name',p.display_name,'handle',p.handle) FROM identity.profiles p WHERE p.user_id=uid
$$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION social.post_document(pid uuid,viewer uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT jsonb_build_object('id',p.id,'author',social.person(p.author_user_id),'context',p.context,'experience_id',p.experience_id,
 'experience_title',(SELECT e.title FROM experiences.experiences e WHERE e.id=p.experience_id),
 'visibility',p.visibility,'body',p.body,'created_at',p.created_at,'updated_at',p.updated_at,'edited_at',p.edited_at,'version',p.version,'can_manage',p.author_user_id=viewer,
 'liked',EXISTS(SELECT FROM social.likes l WHERE l.post_id=p.id AND l.user_id=viewer),
 'like_count',(SELECT count(*) FROM social.likes l WHERE l.post_id=p.id AND social.connected(l.user_id,viewer) AND social.connected(l.user_id,p.author_user_id)),
 'comment_count',(SELECT count(*) FROM social.comments c WHERE c.post_id=p.id AND c.deleted_at IS NULL AND c.moderation_status='VISIBLE' AND social.connected(c.author_user_id,viewer) AND social.connected(c.author_user_id,p.author_user_id)),
 'media',coalesce((SELECT jsonb_agg(jsonb_build_object('id',a.id,'status',a.status,'content_type',CASE WHEN a.duration_ms IS NOT NULL THEN 'video/mp4' ELSE a.content_type END,'size_bytes',a.verified_size,'sha256',a.sha256,'width',a.width,'height',a.height,'duration_ms',a.duration_ms,'failure_code',a.failure_code,'variant','sanitized-v1') ORDER BY m.position) FROM social.post_media m JOIN media.flow_assets a ON a.id=m.asset_id WHERE m.post_id=p.id),'[]'::jsonb))
 FROM social.posts p WHERE p.id=pid AND social.can_read(p.id,viewer)
$$;
-- +goose StatementEnd

DROP FUNCTION social.interaction_visible(uuid,uuid,uuid);
DROP SCHEMA event_space CASCADE;
ALTER TABLE social.posts DROP COLUMN local_hidden;
ALTER TABLE social.comments DROP COLUMN local_hidden;
ALTER TABLE social.posts DROP CONSTRAINT posts_context_check;
ALTER TABLE social.posts DROP CONSTRAINT posts_visibility_check;
ALTER TABLE social.posts DROP CONSTRAINT posts_check;
ALTER TABLE social.posts ADD CONSTRAINT posts_context_check CHECK(context IN ('PERSONAL','EXPERIENCE_PUBLIC'));
ALTER TABLE social.posts ADD CONSTRAINT posts_visibility_check CHECK(visibility IN ('PUBLIC','FOLLOWERS'));
ALTER TABLE social.posts ADD CONSTRAINT posts_check CHECK((context='PERSONAL' AND experience_id IS NULL) OR (context='EXPERIENCE_PUBLIC' AND experience_id IS NOT NULL));
