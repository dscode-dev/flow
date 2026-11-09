-- +goose Up
CREATE SCHEMA social;
CREATE TABLE social.restrictions(user_id uuid PRIMARY KEY REFERENCES identity.users(id), restricted boolean NOT NULL DEFAULT true, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE social.follows(follower_id uuid NOT NULL REFERENCES identity.users(id), followed_id uuid NOT NULL REFERENCES identity.users(id), created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(follower_id,followed_id), CHECK(follower_id<>followed_id));
CREATE INDEX social_followers ON social.follows(followed_id,created_at DESC,follower_id DESC);
CREATE INDEX social_following ON social.follows(follower_id,created_at DESC,followed_id DESC);
CREATE TABLE social.blocks(blocker_id uuid NOT NULL REFERENCES identity.users(id), blocked_id uuid NOT NULL REFERENCES identity.users(id), created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(blocker_id,blocked_id), CHECK(blocker_id<>blocked_id));
CREATE INDEX social_blocks_reverse ON social.blocks(blocked_id,blocker_id);
CREATE TABLE social.posts(
 id uuid PRIMARY KEY, author_user_id uuid NOT NULL REFERENCES identity.users(id),
 experience_id uuid REFERENCES experiences.experiences(id), context text NOT NULL CHECK(context IN ('PERSONAL','EXPERIENCE_PUBLIC')),
 visibility text NOT NULL CHECK(visibility IN ('PUBLIC','FOLLOWERS')), body text NOT NULL CHECK(char_length(body)<=5000),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), edited_at timestamptz, deleted_at timestamptz,
 moderation_status text NOT NULL DEFAULT 'VISIBLE' CHECK(moderation_status IN ('VISIBLE','WITHHELD')),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 CHECK((context='PERSONAL' AND experience_id IS NULL) OR (context='EXPERIENCE_PUBLIC' AND experience_id IS NOT NULL))
);
CREATE INDEX social_feed ON social.posts(created_at DESC,id DESC) WHERE deleted_at IS NULL AND moderation_status='VISIBLE';
CREATE INDEX social_posts_retention ON social.posts(deleted_at,id) WHERE deleted_at IS NOT NULL;
CREATE INDEX social_profile_posts ON social.posts(author_user_id,created_at DESC,id DESC) WHERE deleted_at IS NULL;
ALTER TABLE media.flow_assets ALTER COLUMN experience_id DROP NOT NULL;
ALTER TABLE media.flow_assets ADD COLUMN purpose text NOT NULL DEFAULT 'FLOW' CHECK(purpose IN ('FLOW','SOCIAL'));
ALTER TABLE media.flow_assets ADD CONSTRAINT media_asset_context CHECK((purpose='FLOW' AND experience_id IS NOT NULL) OR (purpose='SOCIAL' AND experience_id IS NULL));
CREATE TABLE social.post_media(post_id uuid NOT NULL REFERENCES social.posts(id) ON DELETE CASCADE, asset_id uuid NOT NULL UNIQUE REFERENCES media.flow_assets(id), position integer NOT NULL CHECK(position BETWEEN 0 AND 3), PRIMARY KEY(post_id,position));
CREATE TABLE social.likes(post_id uuid NOT NULL REFERENCES social.posts(id) ON DELETE CASCADE,user_id uuid NOT NULL REFERENCES identity.users(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(post_id,user_id));
CREATE TABLE social.comments(id uuid PRIMARY KEY,post_id uuid NOT NULL REFERENCES social.posts(id) ON DELETE CASCADE,author_user_id uuid NOT NULL REFERENCES identity.users(id),body text NOT NULL CHECK(char_length(body)<=1000),created_at timestamptz NOT NULL DEFAULT now(),deleted_at timestamptz,moderation_status text NOT NULL DEFAULT 'VISIBLE' CHECK(moderation_status IN ('VISIBLE','WITHHELD')),CHECK(deleted_at IS NOT NULL OR char_length(body)>=1));
CREATE INDEX social_comments_retention ON social.comments(deleted_at,id) WHERE deleted_at IS NOT NULL;
CREATE INDEX social_comments_page ON social.comments(post_id,created_at DESC,id DESC) WHERE deleted_at IS NULL AND moderation_status='VISIBLE';
CREATE TABLE social.reports(id uuid PRIMARY KEY,reporter_user_id uuid NOT NULL REFERENCES identity.users(id),target_type text NOT NULL CHECK(target_type IN ('USER','POST','COMMENT')),target_id uuid NOT NULL,reason text NOT NULL CHECK(reason IN ('ABUSE','SPAM','PRIVACY','ILLEGAL','OTHER')),status text NOT NULL DEFAULT 'OPEN' CHECK(status IN ('OPEN','RESOLVED')),created_at timestamptz NOT NULL DEFAULT now(),resolved_at timestamptz,UNIQUE(reporter_user_id,target_type,target_id));
CREATE INDEX social_reports_retention ON social.reports(created_at,id);
CREATE INDEX social_reports_queue ON social.reports(status,created_at,id);
CREATE TABLE social.audit(id uuid PRIMARY KEY,actor text NOT NULL,resource_id uuid NOT NULL,action text NOT NULL,request_id text NOT NULL,details jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX social_audit_retention ON social.audit(created_at,id);
CREATE TABLE social.receipts(actor_user_id uuid NOT NULL,key uuid NOT NULL,request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),response jsonb NOT NULL,expires_at timestamptz NOT NULL DEFAULT now()+interval '24 hours',PRIMARY KEY(actor_user_id,key));
CREATE INDEX social_receipts_expiry ON social.receipts(expires_at);
CREATE TABLE social.rate_limits(user_id uuid NOT NULL,window_start timestamptz NOT NULL,count integer NOT NULL,PRIMARY KEY(user_id,window_start));
CREATE INDEX social_rate_retention ON social.rate_limits(window_start,user_id);
-- +goose StatementBegin
CREATE FUNCTION social.active(uid uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT FROM identity.users u WHERE u.id=uid AND u.status='active' AND u.onboarding_completed_at IS NOT NULL AND NOT EXISTS(SELECT FROM social.restrictions r WHERE r.user_id=u.id AND r.restricted))
$$;
-- +goose StatementEnd
-- Symmetric at every Social boundary; unblocking never restores follows.
-- +goose StatementBegin
CREATE FUNCTION social.connected(a uuid,b uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT social.active(a) AND social.active(b) AND NOT EXISTS(SELECT FROM social.blocks WHERE (blocker_id=a AND blocked_id=b) OR (blocker_id=b AND blocked_id=a))
$$;
-- +goose StatementEnd
-- PUBLIC only, including after publication. Organizer or currently CONFIRMED.
-- Past published experiences remain eligible; cancellation/archive/restriction do not.
-- +goose StatementBegin
CREATE FUNCTION social.experience_eligible(eid uuid,author uuid,viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT FROM experiences.experiences e WHERE e.id=eid AND e.status='PUBLISHED' AND e.visibility='PUBLIC' AND e.moderation_status='VISIBLE'
 AND social.connected(e.creator_user_id,author) AND social.connected(e.creator_user_id,viewer)
 AND NOT EXISTS(SELECT FROM experiences.publishing_restrictions r WHERE r.creator_user_id=e.creator_user_id AND r.blocked_until>now())
 AND NOT EXISTS(SELECT FROM participation.members b WHERE b.experience_id=e.id AND b.user_id IN (author,viewer) AND b.blocked)
 AND (e.creator_user_id=author OR EXISTS(SELECT FROM participation.members m WHERE m.experience_id=e.id AND m.user_id=author AND m.state='CONFIRMED' AND NOT m.blocked)))
$$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE FUNCTION social.can_read(pid uuid,viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT FROM social.posts p WHERE p.id=pid AND p.deleted_at IS NULL AND p.moderation_status='VISIBLE'
 AND social.connected(p.author_user_id,viewer)
 AND (p.visibility='PUBLIC' OR p.author_user_id=viewer OR EXISTS(SELECT FROM social.follows f WHERE f.follower_id=viewer AND f.followed_id=p.author_user_id))
 AND (p.context='PERSONAL' OR social.experience_eligible(p.experience_id,p.author_user_id,viewer)))
$$;
-- +goose StatementEnd
-- No private identity fields or non-authorized engagement in documents.
-- +goose StatementBegin
CREATE FUNCTION social.person(uid uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT jsonb_build_object('user_id',p.user_id,'display_name',p.display_name,'handle',p.handle) FROM identity.profiles p WHERE p.user_id=uid
$$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE FUNCTION social.post_document(pid uuid,viewer uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
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

-- +goose Down
DROP FUNCTION social.post_document(uuid,uuid);
DROP FUNCTION social.can_read(uuid,uuid);
DROP FUNCTION social.experience_eligible(uuid,uuid,uuid);
DROP FUNCTION social.person(uuid);
DROP FUNCTION social.connected(uuid,uuid);
DROP FUNCTION social.active(uuid);
DROP SCHEMA social CASCADE;
-- Preserve old Flow assets; new Social assets have no prior-domain meaning.
DELETE FROM media.flow_assets WHERE purpose='SOCIAL';
ALTER TABLE media.flow_assets DROP CONSTRAINT media_asset_context;
ALTER TABLE media.flow_assets DROP COLUMN purpose;
ALTER TABLE media.flow_assets ALTER COLUMN experience_id SET NOT NULL;
